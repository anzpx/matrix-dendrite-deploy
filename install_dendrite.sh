#!/bin/bash
set -e

# -------------------------------
# 配置变量
# -------------------------------
INSTALL_DIR="/opt/dendrite"
WEB_DIR="/opt/element-web"
NGINX_DIR="/etc/nginx"
BACKUP_DIR="$INSTALL_DIR/backups"
DOCKER_COMPOSE_FILE="/opt/docker-compose.yml"
LOG_FILE="/var/log/dendrite-deploy.log"

# -------------------------------
# 颜色输出函数
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[警告]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[错误]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[信息]${NC} $1" | tee -a "$LOG_FILE"
}

# -------------------------------
# 工具函数
# -------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "需要 root 权限运行此脚本"
        exit 1
    fi
}

check_system() {
    if ! command -v systemctl &>/dev/null; then
        error "此脚本仅支持 systemd 系统"
        exit 1
    fi
}

confirm() {
    read -p "$1 (y/N): " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) echo "操作已取消"; return 1 ;;
    esac
}

generate_password() {
    head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16
}

get_public_ip() {
    local ip
    ip=$(curl -fsSL -4 ifconfig.me 2>/dev/null || curl -fsSL -6 ifconfig.me 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

is_domain() {
    # 检查是否是域名格式（非IP地址）
    [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

wait_for_service() {
    local service=$1
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if docker compose -f "$DOCKER_COMPOSE_FILE" ps "$service" 2>/dev/null | grep -q "Up"; then
            if [[ "$service" == "postgres" ]]; then
                if docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
                    log "服务 $service 已启动并就绪"
                    return 0
                fi
            else
                log "服务 $service 已启动"
                return 0
            fi
        fi
        warn "等待服务 $service 启动... ($attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    error "服务 $service 启动超时"
    return 1
}

# -------------------------------
# 安装依赖函数
# -------------------------------
install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker 已安装"
        return 0
    fi
    
    log "安装 Docker..."
    curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
    systemctl enable docker --now >> "$LOG_FILE" 2>&1
    sleep 5
    log "Docker 安装完成"
}

install_docker_compose() {
    if docker compose version &>/dev/null; then
        log "Docker Compose 已安装"
        return 0
    fi
    
    log "安装 Docker Compose..."
    local arch
    arch=$(uname -m)
    local compose_version="v2.27.2"
    
    case "$arch" in
        x86_64) arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        armv7l) arch="armv7" ;;
        *) error "不支持的架构: $arch"; return 1 ;;
    esac
    
    curl -L "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$arch" \
        -o /usr/local/bin/docker-compose >> "$LOG_FILE" 2>&1
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    log "Docker Compose 安装完成"
}

install_nginx() {
    if command -v nginx &>/dev/null; then
        log "Nginx 已安装"
        return 0
    fi
    
    log "安装 Nginx..."
    apt update >> "$LOG_FILE" 2>&1
    apt install -y nginx >> "$LOG_FILE" 2>&1
    systemctl enable nginx
    log "Nginx 安装完成"
}

install_certbot() {
    if command -v certbot &>/dev/null; then
        log "Certbot 已安装"
        return 0
    fi
    
    log "安装 Certbot..."
    apt update >> "$LOG_FILE" 2>&1
    apt install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
    log "Certbot 安装完成"
}

# -------------------------------
# 证书管理函数
# -------------------------------
generate_ssl_cert() {
    local server_name=$1
    
    if is_domain "$server_name"; then
        # 使用域名，申请 Let's Encrypt 证书
        log "检测到域名 $server_name，尝试申请 Let's Encrypt 证书..."
        
        if install_certbot; then
            # 检查是否已经存在证书
            if certbot certificates 2>/dev/null | grep -q "$server_name"; then
                log "找到现有证书，使用现有证书"
                SSL_CERT="/etc/letsencrypt/live/$server_name/fullchain.pem"
                SSL_KEY="/etc/letsencrypt/live/$server_name/privkey.pem"
                return 0
            fi
            
            # 停止 nginx 以释放 80 端口进行验证
            systemctl stop nginx || true
            
            # 尝试申请证书
            if certbot certonly --standalone --agree-tos --register-unsafely-without-email \
                -d "$server_name" --non-interactive >> "$LOG_FILE" 2>&1; then
                log "✅ Let's Encrypt 证书申请成功"
                SSL_CERT="/etc/letsencrypt/live/$server_name/fullchain.pem"
                SSL_KEY="/etc/letsencrypt/live/$server_name/privkey.pem"
                
                # 设置证书自动续期
                setup_certbot_renewal "$server_name"
                return 0
            else
                warn "Let's Encrypt 证书申请失败，将使用自签名证书"
            fi
        else
            warn "Certbot 安装失败，将使用自签名证书"
        fi
    fi
    
    # 使用 IP 或证书申请失败时，生成自签名证书
    log "生成自签名 SSL 证书..."
    mkdir -p $NGINX_DIR/ssl
    
    if [[ ! -f $NGINX_DIR/ssl/nginx.crt ]] || [[ ! -f $NGINX_DIR/ssl/nginx.key ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout $NGINX_DIR/ssl/nginx.key \
            -out $NGINX_DIR/ssl/nginx.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$server_name" 2>> "$LOG_FILE"
        log "自签名 SSL 证书生成完成"
    else
        log "自签名 SSL 证书已存在，跳过生成"
    fi
    
    SSL_CERT="$NGINX_DIR/ssl/nginx.crt"
    SSL_KEY="$NGINX_DIR/ssl/nginx.key"
}

setup_certbot_renewal() {
    local domain=$1
    log "设置证书自动续期"
    
    # 创建续期钩子脚本
    cat > /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh << EOF
#!/bin/bash
systemctl reload nginx
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh
    
    # 测试续期
    if certbot renew --dry-run >> "$LOG_FILE" 2>&1; then
        log "证书自动续期测试成功"
    else
        warn "证书自动续期测试失败，请手动检查"
    fi
}

# -------------------------------
# 配置生成函数
# -------------------------------
generate_docker_compose() {
    log "生成 Docker Compose 配置..."
    
    cat > $DOCKER_COMPOSE_FILE <<EOF
services:
  postgres:
    image: postgres:15-alpine
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: "${PGPASS}"
      POSTGRES_DB: dendrite
    volumes:
      - $INSTALL_DIR/pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite"]
      interval: 10s
      timeout: 5s
      retries: 5

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    container_name: dendrite_server
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - $INSTALL_DIR/config:/etc/dendrite
    ports:
      - "127.0.0.1:8008:8008"
      - "127.0.0.1:8448:8448"

  element-web:
    image: vectorim/element-web:latest
    container_name: element_web
    restart: unless-stopped
    volumes:
      - $WEB_DIR/config.json:/app/config.json
    ports:
      - "127.0.0.1:8080:80"
EOF
}

generate_nginx_config() {
    local server_name=$1
    local ssl_cert=$2
    local ssl_key=$3
    
    log "生成 Nginx 配置..."
    
    # 创建配置目录
    mkdir -p $NGINX_DIR/sites-available $NGINX_DIR/sites-enabled
    
    # 检查是否使用 Let's Encrypt 证书
    local is_letsencrypt=false
    if [[ "$ssl_cert" == *"letsencrypt"* ]]; then
        is_letsencrypt=true
        log "使用 Let's Encrypt 证书配置"
    else
        log "使用自签名证书配置"
    fi
    
    cat > $NGINX_DIR/sites-available/matrix <<EOF
server {
    listen 80;
    server_name $server_name;
    
    # 用于 Let's Encrypt 证书续期验证
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        try_files \$uri =404;
    }
    
    # 其他 HTTP 请求重定向到 HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $server_name;

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # 安全头
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";

    # Client-Server API
    location /_matrix/client {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        client_max_body_size 50M;
    }

    # Federation API
    location /_matrix/federation {
        proxy_pass http://127.0.0.1:8448;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        client_max_body_size 50M;
    }

    # Element Web
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 启用站点
    ln -sf $NGINX_DIR/sites-available/matrix $NGINX_DIR/sites-enabled/
    rm -f $NGINX_DIR/sites-enabled/default
    
    # 创建 Let's Encrypt 验证目录
    mkdir -p /var/www/html/.well-known/acme-challenge
    chmod -R 755 /var/www/html
}

generate_element_config() {
    local server_name=$1
    
    log "生成 Element Web 配置..."
    
    cat > $WEB_DIR/config.json <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$server_name",
            "server_name": "$server_name"
        }
    },
    "brand": "Element"
}
EOF
}

generate_dendrite_config() {
    log "生成 Dendrite 配置..."
    
    # 生成密钥
    if [[ ! -f $INSTALL_DIR/config/matrix_key.pem ]]; then
        docker run --rm --entrypoint="/usr/bin/generate-keys" \
            -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
            -private-key /mnt/matrix_key.pem \
            -tls-cert /mnt/server.crt \
            -tls-key /mnt/server.key >> "$LOG_FILE" 2>&1
    fi

    # 生成主配置
    if [[ ! -f $INSTALL_DIR/config/dendrite.yaml ]]; then
        docker run --rm --entrypoint="/usr/bin/generate-config" \
            -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
            -dir /etc/dendrite \
            -db "postgres://dendrite:${PGPASS}@postgres/dendrite?sslmode=disable" \
            -server "$SERVER_NAME" \
            > $INSTALL_DIR/config/dendrite.yaml

        # 修复路径
        sed -i 's#/var/dendrite#/etc/dendrite#g' $INSTALL_DIR/config/dendrite.yaml
        
        # 默认关闭公开注册
        sed -i 's/registration_requires_token: true/registration_requires_token: true/' $INSTALL_DIR/config/dendrite.yaml
    fi
}

configure_shared_secret() {
    log "配置共享密钥..."
    
    SHARED_SECRET=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)
    
    if grep -q "registration_shared_secret" $INSTALL_DIR/config/dendrite.yaml; then
        sed -i "s/registration_shared_secret:.*/registration_shared_secret: \"$SHARED_SECRET\"/" $INSTALL_DIR/config/dendrite.yaml
    else
        sed -i "/client_api:/a\ \ registration_shared_secret: \"$SHARED_SECRET\"" $INSTALL_DIR/config/dendrite.yaml
    fi
}

# -------------------------------
# 维护功能函数
# -------------------------------
enable_registration() {
    log "开启公开用户注册..."
    
    if [ ! -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        error "Dendrite 配置文件不存在"
        return 1
    fi
    
    # 修改配置允许公开注册
    sed -i 's/registration_requires_token: true/registration_requires_token: false/' $INSTALL_DIR/config/dendrite.yaml
    
    # 重启 Dendrite 服务
    docker compose -f "$DOCKER_COMPOSE_FILE" restart dendrite >> "$LOG_FILE" 2>&1
    
    log "✅ 已开启公开用户注册"
    info "现在任何人都可以注册账户，无需邀请"
    
    # 显示当前注册状态
    show_registration_status
}

disable_registration() {
    log "关闭公开用户注册..."
    
    if [ ! -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        error "Dendrite 配置文件不存在"
        return 1
    fi
    
    # 修改配置要求注册令牌
    sed -i 's/registration_requires_token: false/registration_requires_token: true/' $INSTALL_DIR/config/dendrite.yaml
    
    # 重启 Dendrite 服务
    docker compose -f "$DOCKER_COMPOSE_FILE" restart dendrite >> "$LOG_FILE" 2>&1
    
    log "✅ 已关闭公开用户注册"
    info "现在新用户需要注册令牌才能创建账户"
    
    # 显示当前注册状态
    show_registration_status
}

show_registration_status() {
    if [ ! -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        error "Dendrite 配置文件不存在"
        return 1
    fi
    
    local status
    if grep -q "registration_requires_token: false" "$INSTALL_DIR/config/dendrite.yaml"; then
        status="✅ 公开注册已开启 - 任何人都可以注册"
    else
        status="🔒 公开注册已关闭 - 需要注册令牌"
    fi
    
    echo
    echo "=== 注册状态 ==="
    echo "$status"
    echo
}

backup_database() {
    log "开始备份数据库..."
    
    mkdir -p "$BACKUP_DIR"
    DATE=$(date +'%Y%m%d_%H%M%S')
    BACKUP_FILE="$BACKUP_DIR/dendrite_backup_$DATE.sql"
    
    if ! docker compose -f "$DOCKER_COMPOSE_FILE" ps postgres | grep -q "Up"; then
        error "PostgreSQL 服务未运行，无法备份"
        return 1
    fi
    
    info "正在备份数据库到 $BACKUP_FILE..."
    
    if docker exec dendrite_postgres pg_dump -U dendrite dendrite > "$BACKUP_FILE" 2>> "$LOG_FILE"; then
        # 压缩备份文件
        gzip "$BACKUP_FILE"
        local backup_size
        backup_size=$(du -h "${BACKUP_FILE}.gz" | cut -f1)
        log "备份完成: ${BACKUP_FILE}.gz (${backup_size})"
        
        # 清理旧备份（保留最近7天）
        find "$BACKUP_DIR" -name "dendrite_backup_*.sql.gz" -mtime +7 -delete >> "$LOG_FILE" 2>&1
    else
        error "数据库备份失败"
        return 1
    fi
}

view_backups() {
    log "查看备份文件..."
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        warn "备份目录为空或不存在"
        return 1
    fi
    
    echo
    echo "=== 备份文件列表 ==="
    ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null | awk '{print $6" "$7" "$8" "$9}' | while read line; do
        echo "📦 $line"
    done
    
    local total_size
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    echo
    info "备份目录总大小: $total_size"
}

clean_old_backups() {
    log "清理旧备份..."
    
    if confirm "确定要删除7天前的备份文件吗？"; then
        local deleted_count
        deleted_count=$(find "$BACKUP_DIR" -name "dendrite_backup_*.sql.gz" -mtime +7 -delete -print | wc -l)
        
        if [ "$deleted_count" -gt 0 ]; then
            log "已删除 $deleted_count 个旧备份文件"
        else
            info "没有找到需要删除的旧备份文件"
        fi
    fi
}

create_new_user() {
    log "创建新用户..."
    
    read -p "请输入新用户名: " username
    if [[ -z "$username" ]]; then
        error "用户名不能为空"
        return 1
    fi
    
    local password
    password=$(generate_password)
    
    info "新用户账号: $username"
    info "初始密码: $password"
    
    # 等待Dendrite完全启动
    sleep 5
    
    if docker exec dendrite_server /usr/bin/create-account \
        -config /etc/dendrite/dendrite.yaml \
        -username "$username" \
        -password "$password" >> "$LOG_FILE" 2>&1; then
        log "✅ 用户 $username 创建成功"
        echo
        echo "用户信息:"
        echo "用户名: $username"
        echo "密码: $password"
        echo
        info "请提醒用户首次登录后修改密码"
    else
        error "用户创建失败"
        return 1
    fi
}

# -------------------------------
# 服务管理函数
# -------------------------------
start_services() {
    log "启动服务..."
    
    # 启动Docker服务
    docker compose -f $DOCKER_COMPOSE_FILE up -d >> "$LOG_FILE" 2>&1
    
    # 等待PostgreSQL启动
    info "等待数据库启动..."
    wait_for_service postgres || return 1
    
    # 启动 Nginx
    systemctl start nginx >> "$LOG_FILE" 2>&1
    
    # 测试Nginx配置并重启
    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl reload nginx >> "$LOG_FILE" 2>&1
        log "Nginx 配置验证并重启完成"
    else
        error "Nginx 配置验证失败"
        return 1
    fi
    
    # 等待其他服务启动
    wait_for_service dendrite || warn "Dendrite 启动较慢"
    wait_for_service element-web || warn "Element Web 启动较慢"
    
    log "所有服务启动完成"
}

create_admin_user() {
    log "创建管理员账户..."
    
    ADMIN_USER="admin"
    ADMIN_PASS=$(generate_password)
    
    info "管理员账号: $ADMIN_USER"
    info "管理员密码: $ADMIN_PASS"
    info "请妥善保存这些信息！"
    
    # 等待Dendrite完全启动
    info "等待 Dendrite 启动..."
    sleep 20
    
    local attempt=1
    while [[ $attempt -le 5 ]]; do
        if docker exec dendrite_server /usr/bin/create-account \
            -config /etc/dendrite/dendrite.yaml \
            -username "$ADMIN_USER" \
            -password "$ADMIN_PASS" \
            -admin >> "$LOG_FILE" 2>&1; then
            log "管理员账户创建成功"
            return 0
        fi
        warn "创建管理员账户失败，重试... ($attempt/5)"
        sleep 10
        ((attempt++))
    done
    
    warn "管理员账户创建失败，请手动创建"
    return 1
}

test_services() {
    log "测试服务访问..."
    
    echo
    echo "=== 服务状态 ==="
    docker compose -f $DOCKER_COMPOSE_FILE ps
    
    echo
    echo "=== 连接测试 ==="
    info "HTTPS 测试:"
    local status_code
    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$SERVER_NAME/" || echo "000")
    
    if [ "$status_code" = "200" ]; then
        log "✅ Element Web 访问正常"
    else
        warn "⚠ Element Web 访问可能有问题 (状态码: $status_code)"
    fi
    
    info "Matrix API 测试:"
    if curl -k -s "https://$SERVER_NAME/_matrix/client/versions" | grep -q "versions"; then
        log "✅ Matrix Client API 正常"
    else
        warn "⚠ Matrix Client API 可能有问题"
    fi
    
    # 显示证书信息
    echo
    info "证书信息:"
    if is_domain "$SERVER_NAME" && [[ "$SSL_CERT" == *"letsencrypt"* ]]; then
        log "✅ 使用 Let's Encrypt 证书 (浏览器受信任)"
        if command -v certbot &>/dev/null; then
            certbot certificates 2>/dev/null | grep -A10 "$SERVER_NAME" | head -5 || true
        fi
    else
        log "ℹ️  使用自签名证书 (浏览器会显示安全警告)"
        warn "注意: 自签名证书在浏览器中会显示安全警告，这是正常现象"
        warn "如需消除警告，请使用域名并确保DNS解析正确"
    fi
}

# -------------------------------
# 主安装函数
# -------------------------------
install_dendrite() {
    log "开始安装 Matrix Dendrite..."
    
    # 获取服务器地址
    PUBLIC_IP=$(get_public_ip)
    if [[ -z "$PUBLIC_IP" ]]; then
        read -p "无法获取公网 IP，请手动输入服务器公网 IP 或域名: " PUBLIC_IP
    fi

    read -p "请输入域名（回车使用 IP: ${PUBLIC_IP}）: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$PUBLIC_IP}
    
    if [[ -z "$SERVER_NAME" ]]; then
        error "服务器地址不能为空"
        return 1
    fi
    
    info "使用地址: $SERVER_NAME"
    
    # 创建目录
    mkdir -p $INSTALL_DIR/{config,pgdata,logs} $WEB_DIR $BACKUP_DIR
    
    # 安装依赖
    install_docker || return 1
    install_docker_compose || return 1
    install_nginx || return 1
    
    # 生成密码
    PGPASS=$(generate_password)
    
    # 生成SSL证书（智能选择）
    SSL_CERT=""
    SSL_KEY=""
    generate_ssl_cert "$SERVER_NAME"
    
    # 生成配置
    generate_docker_compose || return 1
    generate_nginx_config "$SERVER_NAME" "$SSL_CERT" "$SSL_KEY" || return 1
    generate_element_config "$SERVER_NAME" || return 1
    generate_dendrite_config || return 1
    configure_shared_secret || return 1
    
    # 启动服务
    start_services || return 1
    
    # 创建管理员
    create_admin_user || warn "管理员账户创建可能需要手动完成"
    
    # 测试服务
    test_services
    
    show_success_message
}

show_success_message() {
    echo
    echo "======================================"
    echo "🎉 Matrix Dendrite 安装完成！"
    echo "======================================"
    echo "访问地址: https://$SERVER_NAME"
    echo "管理员账号: admin"
    echo "管理员密码: $ADMIN_PASS"
    echo
    
    if is_domain "$SERVER_NAME" && [[ "$SSL_CERT" == *"letsencrypt"* ]]; then
        echo "✅ 使用 Let's Encrypt 证书 - 浏览器完全信任"
        echo "📅 证书将自动续期，无需手动管理"
    else
        echo "ℹ️  使用自签名证书 - 浏览器会显示安全警告"
        echo "⚠️  如需消除警告："
        echo "   1. 请使用域名而不是IP地址"
        echo "   2. 确保域名DNS正确解析到本服务器"
        echo "   3. 重新运行安装脚本选择域名"
    fi
    
    echo
    echo "重要提示:"
    echo "1. 查看日志: docker compose -f $DOCKER_COMPOSE_FILE logs"
    echo "2. 备份目录: $BACKUP_DIR"
    echo "3. 当前注册策略: 🔒 需要注册令牌 (可在维护菜单中修改)"
    echo "======================================"
}

# -------------------------------
# 卸载和维护函数
# -------------------------------
complete_uninstall() {
    if confirm "确定要完全卸载并删除所有数据吗？此操作不可恢复！"; then
        log "开始完全卸载 Matrix Dendrite..."
        
        # 停止并删除容器
        if [ -f "$DOCKER_COMPOSE_FILE" ]; then
            docker compose -f "$DOCKER_COMPOSE_FILE" down -v >> "$LOG_FILE" 2>&1 || true
        fi
        
        # 删除所有相关目录和文件
        rm -rf "$INSTALL_DIR" "$WEB_DIR" "$DOCKER_COMPOSE_FILE"
        
        # 清理 Nginx 配置
        rm -f "$NGINX_DIR/sites-available/matrix" "$NGINX_DIR/sites-enabled/matrix"
        
        # 清理 Docker 资源
        docker system prune -f >> "$LOG_FILE" 2>&1 || true
        
        log "完全卸载完成，所有数据已删除"
    else
        log "卸载操作已取消"
    fi
}

upgrade_services() {
    log "开始升级服务..."
    
    if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
        error "未找到 Docker Compose 文件，请先安装服务"
        return 1
    fi
    
    # 拉取最新镜像
    info "拉取最新 Docker 镜像..."
    docker compose -f "$DOCKER_COMPOSE_FILE" pull >> "$LOG_FILE" 2>&1
    
    # 重启服务
    docker compose -f "$DOCKER_COMPOSE_FILE" down >> "$LOG_FILE" 2>&1
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1
    
    # 等待服务启动
    info "等待服务启动..."
    wait_for_service postgres
    wait_for_service dendrite
    wait_for_service element-web
    
    log "服务升级完成"
}

show_status() {
    log "服务状态检查..."
    
    if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
        error "未找到 Docker Compose 文件，服务可能未安装"
        return 1
    fi
    
    echo
    echo "======================================"
    echo "           服务状态信息"
    echo "======================================"
    
    # Docker Compose 状态
    docker compose -f "$DOCKER_COMPOSE_FILE" ps
    
    echo
    echo "--------------------------------------"
    echo "Nginx 状态:"
    systemctl status nginx --no-pager -l | head -10
    
    echo
    echo "--------------------------------------"
    echo "证书信息:"
    if is_domain "$SERVER_NAME" 2>/dev/null && command -v certbot &>/dev/null; then
        certbot certificates 2>/dev/null | grep -A20 "$SERVER_NAME" || echo "未找到 Let's Encrypt 证书"
    else
        echo "使用自签名证书"
    fi
    
    # 显示注册状态
    show_registration_status
    
    echo "======================================"
}

# -------------------------------
# 维护菜单
# -------------------------------
maintenance_menu() {
    echo
    echo "======================================"
    echo "           Matrix 维护菜单"
    echo "======================================"
    echo
    echo "请选择维护操作："
    echo "1) 开启公开用户注册"
    echo "2) 关闭公开用户注册 (需要注册令牌)"
    echo "3) 查看当前注册状态"
    echo "4) 创建新用户账户"
    echo "5) 备份数据库"
    echo "6) 查看备份文件"
    echo "7) 清理旧备份"
    echo "0) 返回主菜单"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) enable_registration ;;
        2) disable_registration ;;
        3) show_registration_status ;;
        4) create_new_user ;;
        5) backup_database ;;
        6) view_backups ;;
        7) clean_old_backups ;;
        0) return ;;
        *) error "无效选项"; maintenance_menu ;;
    esac
    
    # 返回维护菜单
    if [ $? -eq 0 ]; then
        read -p "按回车键继续..."
        maintenance_menu
    fi
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 一键部署脚本 (Nginx版)"
    echo "======================================"
    echo
    echo "请选择操作："
    echo "1) 安装/部署 Matrix Dendrite"
    echo "2) 完全卸载（删除所有数据）"
    echo "3) 升级服务"
    echo "4) 查看服务状态"
    echo "5) 查看服务日志"
    echo "6) 维护菜单"
    echo "0) 退出"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) install_dendrite ;;
        2) complete_uninstall ;;
        3) upgrade_services ;;
        4) show_status ;;
        5) 
            echo "选择要查看的日志："
            echo "1) 所有服务日志"
            echo "2) Dendrite 日志"
            echo "3) PostgreSQL 日志"
            echo "4) Element Web 日志"
            echo "5) Nginx 日志"
            read -p "请输入数字: " log_choice
            case "$log_choice" in
                1) docker compose -f "$DOCKER_COMPOSE_FILE" logs -f ;;
                2) docker compose -f "$DOCKER_COMPOSE_FILE" logs -f dendrite ;;
                3) docker compose -f "$DOCKER_COMPOSE_FILE" logs -f postgres ;;
                4) docker compose -f "$DOCKER_COMPOSE_FILE" logs -f element-web ;;
                5) tail -f /var/log/nginx/access.log /var/log/nginx/error.log ;;
            esac
            ;;
        6) maintenance_menu ;;
        0) echo "退出脚本"; exit 0 ;;
        *) error "无效选项"; main_menu ;;
    esac
}

# -------------------------------
# 脚本入口
# -------------------------------
check_root
check_system

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log "脚本开始执行"

# 显示主菜单
main_menu
