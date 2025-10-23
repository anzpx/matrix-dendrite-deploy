#!/bin/bash
set -e

# 日志和目录
LOG_DIR="/opt/dendrite/logs"
CONFIG_DIR="/opt/dendrite/config"
DATA_DIR="/opt/dendrite/data"
CERT_DIR="/opt/dendrite/certs"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示菜单
show_menu() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}    Matrix Dendrite 部署脚本${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1. 安装 Dendrite${NC}"
    echo -e "${YELLOW}2. 重新安装 Dendrite${NC}"
    echo -e "${RED}0. 退出${NC}"
    echo -e "${BLUE}======================================${NC}"
}

# 安装函数
install_dendrite() {
    echo -e "${GREEN}[开始安装 Dendrite]${NC}"
    
    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$DATA_DIR/postgres" "$DATA_DIR/media_store" "$CERT_DIR"
    exec > >(tee -a "$LOG_DIR/install.log") 2>&1

    # 获取 VPS IP
    VPS_IP=$(curl -s ifconfig.me)

    # 输入域名/IP，如果回车则使用 VPS IP
    read -p "请输入域名或 VPS IP (回车自动使用 VPS IP: $VPS_IP): " DOMAIN
    DOMAIN=${DOMAIN:-$VPS_IP}

    # 输入数据库密码，如果回车则随机生成
    read -s -p "请输入 PostgreSQL 数据库密码 (回车随机生成): " DB_PASS
    echo
    DB_PASS=${DB_PASS:-$(openssl rand -base64 12)}

    # 输入管理员用户名，如果回车则随机生成
    read -p "请输入管理员账号用户名 (回车随机生成): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-user_$(openssl rand -hex 5)}

    # 输入管理员密码，如果回车则随机生成
    read -s -p "请输入管理员账号密码 (回车随机生成): " ADMIN_PASS
    echo
    ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -base64 12)}

    echo
    echo "使用配置如下:"
    echo "域名/IP: $DOMAIN"
    echo "数据库密码: $DB_PASS"
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "======================================"

    # 系统检查
    if ! grep -q "Ubuntu" /etc/os-release; then
        echo -e "${RED}脚本仅支持 Ubuntu 系统${NC}"
        exit 1
    fi

    # 安装依赖
    echo "[1/7] 安装 Docker / Docker Compose / Nginx / Certbot / dnsutils"
    apt update -y
    apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils
    systemctl enable --now docker

    # 检测域名解析
    DNS_IP=$(dig +short "$DOMAIN" | head -n1)
    USE_LETSENCRYPT="no"
    if [[ "$DNS_IP" == "$VPS_IP" ]]; then
        echo "✅ 域名解析正确，启用 Let's Encrypt"
        USE_LETSENCRYPT="yes"
    else
        echo "⚠️ 域名未解析到 VPS 公网 IP，将使用自签名证书"
        DOMAIN="$VPS_IP"
    fi

    # 设置权限
    chown -R $(whoami):$(whoami) "/opt/dendrite"
    chmod -R 755 "$CONFIG_DIR"

    # 使用 Ed25519 生成私钥
    echo "[2/7] 生成 Dendrite 私钥 (Ed25519)"
    openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem"
    chmod 644 "$CONFIG_DIR/matrix_key.pem"

    # 创建 Dendrite 配置文件
    echo "[3/7] 创建完整配置文件"
    cat > "$CONFIG_DIR/dendrite.yaml" <<EOF
global:
  server_name: $DOMAIN
  private_key: /etc/dendrite/matrix_key.pem
  well_known_server_name: https://$DOMAIN
  presence:
    enable_inbound: true
    enable_outbound: true

database:
  connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

app_service_api:
  internal_api:
    connect: http://dendrite:7777
    listen: http://0.0.0.0:7777

client_api:
  internal_api:
    connect: http://dendrite:7771
    listen: http://0.0.0.0:7771
  external_api:
    listen: http://0.0.0.0:8008

federation_api:
  internal_api:
    connect: http://dendrite:7772
    listen: http://0.0.0.0:7772
  external_api:
    listen: http://0.0.0.0:8448

key_server:
  internal_api:
    connect: http://dendrite:7774
    listen: http://0.0.0.0:7774

media_api:
  internal_api:
    connect: http://dendrite:7775
    listen: http://0.0.0.0:7775
  external_api:
    listen: http://0.0.0.0:8075
  base_path: /etc/dendrite/media_store

room_server:
  internal_api:
    connect: http://dendrite:7773
    listen: http://0.0.0.0:7773

sync_api:
  internal_api:
    connect: http://dendrite:7773
    listen: http://0.0.0.0:7773

user_api:
  internal_api:
    connect: http://dendrite:7781
    listen: http://0.0.0.0:7781
  account_database:
    connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

logging:
- type: file
  level: info
  params:
    path: /var/log/dendrite.log
EOF

    # 创建 Docker Compose 文件
    echo "[4/7] 创建 Docker Compose 配置"
    cat > /opt/dendrite/docker-compose.yml <<EOF
version: '3.7'
services:
  postgres:
    image: postgres:15
    environment:
      - POSTGRES_USER=dendrite
      - POSTGRES_PASSWORD=$DB_PASS
      - POSTGRES_DB=dendrite
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite -d dendrite"]
      interval: 10s
      timeout: 5s
      retries: 5

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
      - ./data/media_store:/etc/dendrite/media_store
      - ./logs:/var/log
    command:
      - "/usr/bin/dendrite-monolith"
      - "--config"
      - "/etc/dendrite/dendrite.yaml"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8008/_matrix/client/versions"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
EOF

    # 启动服务
    echo "[5/7] 启动服务"
    cd /opt/dendrite
    docker-compose down -v || true
    docker-compose up -d

    # 等待服务完全启动
    echo "等待服务启动..."
    sleep 30

    # 等待 Dendrite 容器健康
    echo "等待 Dendrite 容器健康..."
    for i in {1..60}; do
        if docker-compose exec -T dendrite curl -f http://localhost:8008/_matrix/client/versions > /dev/null 2>&1; then
            echo "✅ Dendrite 服务已就绪"
            break
        fi
        echo "等待 Dendrite 服务就绪... ($i/60)"
        sleep 5
    done

    # 创建管理员账号，最多重试20次
    echo "[6/7] 创建管理员账号"
    for i in {1..20}; do
        if docker-compose exec -T dendrite \
            /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
            --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin 2>/dev/null; then
            echo "✅ 管理员账号创建成功"
            break
        else
            echo "⚠️ 管理员账号创建失败，等待重试... ($i/20)"
            sleep 10
        fi
        if [ $i -eq 20 ]; then
            echo "❌ 管理员账号创建失败，请手动执行以下命令："
            echo "cd /opt/dendrite && docker-compose exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml --username \"$ADMIN_USER\" --password \"$ADMIN_PASS\" --admin"
        fi
    done

    # 配置 Nginx
    echo "[7/7] 配置 Nginx"
    NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        echo "配置 Nginx + Let's Encrypt"
        cat > $NGINX_CONF <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGX
    else
        echo "配置 Nginx + 自签名证书"
        SSL_KEY="$CERT_DIR/selfsigned.key"
        SSL_CRT="$CERT_DIR/selfsigned.crt"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_KEY" -out "$SSL_CRT" \
            -subj "/CN=$DOMAIN" 2>/dev/null
        cat > $NGINX_CONF <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate $SSL_CRT;
    ssl_certificate_key $SSL_KEY;
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGX
    fi

    ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl restart nginx

    # 如果是域名且解析正确，申请 SSL
    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        echo "申请 Let's Encrypt SSL 证书..."
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" || \
        echo "Certbot 证书申请失败，请检查域名解析"
    fi

    echo "======================================"
    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        echo "访问地址: https://$DOMAIN"
    else
        echo "HTTP 地址: http://$DOMAIN:8008"
        echo "HTTPS 地址（自签名证书）: https://$DOMAIN"
    fi
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "数据库密码: $DB_PASS"
    echo "日志路径: $LOG_DIR"
    echo "======================================"
    echo "检查服务状态: cd /opt/dendrite && docker-compose ps"
    echo "查看 Dendrite 日志: cd /opt/dendrite && docker-compose logs dendrite"
    echo "查看 PostgreSQL 日志: cd /opt/dendrite && docker-compose logs postgres"
    echo "重启服务: cd /opt/dendrite && docker-compose restart"
    
    echo -e "${GREEN}[安装完成]${NC}"
}

# 重新安装函数
reinstall_dendrite() {
    echo -e "${YELLOW}[开始重新安装 Dendrite]${NC}"
    
    # 确认操作
    read -p "重新安装将删除所有现有数据，是否继续? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消重新安装${NC}"
        return
    fi

    # 备份现有配置
    if [ -d "/opt/dendrite" ]; then
        BACKUP_DIR="/opt/dendrite_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        
        echo "备份现有配置到: $BACKUP_DIR"
        cp -r /opt/dendrite/config/* "$BACKUP_DIR/" 2>/dev/null || true
        
        # 停止并删除现有容器
        echo "停止并删除现有容器..."
        cd /opt/dendrite
        docker-compose down -v || true
    fi

    # 完全清理
    echo "清理旧数据..."
    cd /opt
    rm -rf dendrite

    # 重新安装
    install_dendrite
}

# 主循环
while true; do
    show_menu
    read -p "请选择操作 [0-2]: " choice
    
    case $choice in
        1)
            install_dendrite
            break
            ;;
        2)
            reinstall_dendrite
            break
            ;;
        0)
            echo -e "${BLUE}退出脚本${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${NC}"
            ;;
    esac
done
