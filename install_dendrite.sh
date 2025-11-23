#!/bin/bash
set -e

# 配置变量
INSTALL_DIR="/opt/dendrite"
WEB_DIR="/opt/element-web"
NGINX_DIR="/etc/nginx"
BACKUP_DIR="$INSTALL_DIR/backups"
DOCKER_COMPOSE_FILE="/opt/docker-compose.yml"
LOG_FILE="/var/log/dendrite-deploy.log"

# 颜色输出函数
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[警告]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[错误]${NC} $1" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[信息]${NC} $1" | tee -a "$LOG_FILE"; }

# 确认函数
confirm() {
    read -p "$1 (y/N): " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) echo "操作已取消"; return 1 ;;
    esac
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "需要 root 权限运行此脚本"
        exit 1
    fi
}

# 生成随机密码
generate_password() {
    head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16
}

# 获取公网IP
get_public_ip() {
    local ip
    ip=$(curl -fsSL -4 ifconfig.me 2>/dev/null || curl -fsSL -6 ifconfig.me 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

# 安装Docker
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

# 安装Docker Compose
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

# 安装Nginx
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

# 生成SSL证书
generate_ssl_cert() {
    log "生成 SSL 证书..."
    mkdir -p $NGINX_DIR/ssl
    
    if [[ ! -f $NGINX_DIR/ssl/nginx.crt ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout $NGINX_DIR/ssl/nginx.key \
            -out $NGINX_DIR/ssl/nginx.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$SERVER_NAME" 2>> "$LOG_FILE"
        log "SSL 证书生成完成"
    else
        log "SSL 证书已存在，跳过生成"
    fi
}

# 生成Docker Compose配置
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

# 生成Nginx配置
generate_nginx_config() {
    log "生成 Nginx 配置..."
    
    cat > $NGINX_DIR/sites-available/matrix <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $SERVER_NAME;

    ssl_certificate $NGINX_DIR/ssl/nginx.crt;
    ssl_certificate_key $NGINX_DIR/ssl/nginx.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=63072000" always;

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
}

# 生成Element Web配置
generate_element_config() {
    log "生成 Element Web 配置..."
    
    cat > $WEB_DIR/config.json <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$SERVER_NAME",
            "server_name": "$SERVER_NAME"
        }
    },
    "brand": "Element"
}
EOF
}

# 生成Dendrite配置
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
        
        # 启用开放注册
        sed -i 's/registration_requires_token: true/registration_requires_token: false/' $INSTALL_DIR/config/dendrite.yaml
    fi
}

# 配置共享密钥
configure_shared_secret() {
    log "配置共享密钥..."
    
    SHARED_SECRET=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)
    
    if grep -q "registration_shared_secret" $INSTALL_DIR/config/dendrite.yaml; then
        sed -i "s/registration_shared_secret:.*/registration_shared_secret: \"$SHARED_SECRET\"/" $INSTALL_DIR/config/dendrite.yaml
    else
        sed -i "/client_api:/a\ \ registration_shared_secret: \"$SHARED_SECRET\"" $INSTALL_DIR/config/dendrite.yaml
    fi
}

# 创建管理员账户
create_admin_user() {
    log "创建管理员账户..."
    
    ADMIN_USER="admin"
    ADMIN_PASS=$(generate_password)
    
    info "管理员账号: $ADMIN_USER"
    info "管理员密码: $ADMIN_PASS"
    
    # 等待Dendrite启动
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

# 启动服务
start_services() {
    log "启动服务..."
    
    # 启动Docker服务
    docker compose -f $DOCKER_COMPOSE_FILE up -d >> "$LOG_FILE" 2>&1
    
    # 等待PostgreSQL启动
    info "等待数据库启动..."
    local attempt=1
    while [[ $attempt -le 30 ]]; do
        if docker compose -f $DOCKER_COMPOSE_FILE ps postgres | grep -q "Up" && \
           docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
            log "数据库已就绪"
            break
        fi
        warn "等待数据库... ($attempt/30)"
        sleep 5
        ((attempt++))
    done
    
    # 测试Nginx配置并重启
    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl restart nginx >> "$LOG_FILE" 2>&1
        log "Nginx 配置验证并重启完成"
    else
        error "Nginx 配置验证失败"
        return 1
    fi
    
    log "所有服务启动完成"
}

# 测试服务
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
}

# 显示成功信息
show_success_message() {
    echo
    echo "======================================"
    echo "🎉 Matrix Dendrite 安装完成！"
    echo "======================================"
    echo "访问地址: https://$SERVER_NAME"
    echo "管理员账号: admin"
    echo "管理员密码: $ADMIN_PASS"
    echo
    echo "重要提示:"
    echo "1. 由于使用自签名证书，浏览器会显示不安全警告"
    echo "2. 在手机上访问时，需要点击'高级'->'继续访问'"
    echo "3. 如需域名证书，请替换 SSL 证书文件"
    echo "4. 查看日志: docker compose -f $DOCKER_COMPOSE_FILE logs"
    echo "======================================"
}

# 主安装函数
main_install() {
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
    
    # 生成配置
    generate_ssl_cert || return 1
    generate_docker_compose || return 1
    generate_nginx_config || return 1
    generate_element_config || return 1
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

# 卸载函数
uninstall() {
    if confirm "确定要卸载 Matrix Dendrite 吗？此操作将删除所有数据。"; then
        log "开始卸载..."
        
        docker compose -f $DOCKER_COMPOSE_FILE down -v 2>/dev/null || true
        rm -rf $INSTALL_DIR $WEB_DIR $DOCKER_COMPOSE_FILE
        rm -f $NGINX_DIR/sites-available/matrix $NGINX_DIR/sites-enabled/matrix
        
        log "卸载完成"
    fi
}

# 主菜单
main_menu() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 一键部署脚本 (Nginx版)"
    echo "======================================"
    echo
    echo "请选择操作："
    echo "1) 安装 Matrix Dendrite"
    echo "2) 完全卸载"
    echo "3) 查看服务状态"
    echo "0) 退出"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) main_install ;;
        2) uninstall ;;
        3) 
            echo "=== 服务状态 ==="
            docker compose -f $DOCKER_COMPOSE_FILE ps 2>/dev/null || echo "服务未运行"
            echo
            echo "=== Nginx 状态 ==="
            systemctl status nginx --no-pager -l 2>/dev/null || echo "Nginx 未安装"
            ;;
        0) echo "退出脚本"; exit 0 ;;
        *) error "无效选项" ;;
    esac
}

# 脚本入口
check_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log "脚本开始执行"
main_menu
