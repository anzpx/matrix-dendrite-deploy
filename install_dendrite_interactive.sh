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
    echo -e "${BLUE}    Matrix Dendrite 自动部署脚本${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1. 安装 Dendrite${NC}"
    echo -e "${YELLOW}2. 重新安装 Dendrite${NC}"
    echo -e "${RED}0. 退出${NC}"
    echo -e "${BLUE}======================================${NC}"
}

# 检查服务状态
check_service_status() {
    echo -e "${YELLOW}检查服务状态...${NC}"
    cd /opt/dendrite
    echo -e "${BLUE}容器状态:${NC}"
    docker-compose ps
    echo -e "${BLUE}PostgreSQL 日志 (最后20行):${NC}"
    docker-compose logs postgres --tail=20
    echo -e "${BLUE}Dendrite 日志 (最后30行):${NC}"
    docker-compose logs dendrite --tail=30
    echo -e "${BLUE}端口监听状态:${NC}"
    netstat -tlnp | grep -E ':(8008|8448|5432)' || echo "相关端口未监听"
}

# 等待 PostgreSQL 就绪
wait_for_postgres() {
    echo "[*] 等待 PostgreSQL 启动..."
    until docker-compose exec -T postgres pg_isready -U dendrite -d dendrite >/dev/null 2>&1; do
        echo "PostgreSQL 未就绪，等待 5 秒..."
        sleep 5
    done
    echo "PostgreSQL 已就绪"
}

# 等待 Dendrite 就绪
wait_for_dendrite() {
    echo "[*] 等待 Dendrite 容器就绪..."
    until docker-compose exec -T dendrite /usr/bin/dendrite-monolith --version >/dev/null 2>&1; do
        echo "Dendrite 容器未就绪，等待 5 秒..."
        sleep 5
    done
    echo "Dendrite 已就绪"
}

# 安装函数
install_dendrite() {
    echo -e "${GREEN}[开始安装 Dendrite]${NC}"

    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$DATA_DIR/postgres" "$DATA_DIR/media_store" "$CERT_DIR"
    exec > >(tee -a "$LOG_DIR/install.log") 2>&1

    VPS_IP=$(curl -s ifconfig.me)
    read -p "请输入域名或 VPS IP (回车自动使用 VPS IP: $VPS_IP): " DOMAIN
    DOMAIN=${DOMAIN:-$VPS_IP}

    read -s -p "请输入 PostgreSQL 数据库密码 (回车随机生成): " DB_PASS
    echo
    DB_PASS=${DB_PASS:-$(openssl rand -base64 12)}

    read -p "请输入管理员账号用户名 (回车随机生成): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-user_$(openssl rand -hex 5)}

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

    if ! grep -q "Ubuntu" /etc/os-release; then
        echo -e "${RED}脚本仅支持 Ubuntu 系统${NC}"
        exit 1
    fi

    echo "[1/7] 安装依赖"
    apt update -y
    apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl
    systemctl enable --now docker

    DNS_IP=$(dig +short "$DOMAIN" | head -n1)
    USE_LETSENCRYPT="no"
    if [[ "$DNS_IP" == "$VPS_IP" ]] && [[ "$DOMAIN" != "$VPS_IP" ]]; then
        echo "✅ 域名解析正确，启用 Let's Encrypt"
        USE_LETSENCRYPT="yes"
    else
        echo "⚠️ 域名未解析到 VPS 公网 IP，将使用自签名证书"
        DOMAIN="$VPS_IP"
    fi

    chown -R $(whoami):$(whoami) "/opt/dendrite"
    chmod -R 755 "$CONFIG_DIR"

    echo "[2/7] 生成私钥"
    openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem"
    chmod 644 "$CONFIG_DIR/matrix_key.pem"  # ✅ 容器可读权限

    echo "[3/7] 创建 Dendrite 配置文件"
    cat > "$CONFIG_DIR/dendrite.yaml" <<EOF
global:
  server_name: $DOMAIN
  private_key: /etc/dendrite/matrix_key.pem

database:
  connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

client_api:
  internal_api:
    connect: http://localhost:7771
    listen: http://0.0.0.0:7771
  external_api:
    listen: http://0.0.0.0:8008

federation_api:
  internal_api:
    connect: http://localhost:7772
    listen: http://0.0.0.0:7772
  external_api:
    listen: http://0.0.0.0:8448

media_api:
  internal_api:
    connect: http://localhost:7775
    listen: http://0.0.0.0:7775
  external_api:
    listen: http://0.0.0.0:8075
  base_path: /etc/dendrite/media_store

sync_api:
  internal_api:
    connect: http://localhost:7773
    listen: http://0.0.0.0:7773

user_api:
  internal_api:
    connect: http://localhost:7781
    listen: http://0.0.0.0:7781
  account_database:
    connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

logging:
- type: file
  level: info
  params:
    path: /var/log/dendrite.log
EOF

    echo "[4/7] 创建 Docker Compose 文件"
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
      interval: 5s
      timeout: 5s
      retries: 10

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    depends_on:
      - postgres
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite:ro  # ✅ 只读挂载，容器可读
      - ./data/media_store:/etc/dendrite/media_store
      - ./logs:/var/log
    command: /usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml
    restart: unless-stopped
EOF

    echo "[5/7] 启动服务"
    cd /opt/dendrite
    docker-compose down -v || true
    docker-compose up -d

    wait_for_postgres
    wait_for_dendrite

    echo "[6/7] 创建管理员账号"
    docker-compose exec -T dendrite \
        /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
        --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin

    echo "[7/7] 配置 Nginx"
    NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
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
    ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" || \
        echo "⚠️ Certbot 证书申请失败，请检查域名解析"
    fi

    echo "======================================"
    echo "访问地址: $( [[ "$USE_LETSENCRYPT" == "yes" ]] && echo "https" || echo "http" )://$DOMAIN"
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "数据库密码: $DB_PASS"
    echo "======================================"
    check_service_status
    echo -e "${GREEN}[安装完成]${NC}"
}

# 重新安装
reinstall_dendrite() {
    echo -e "${YELLOW}[开始重新安装 Dendrite]${NC}"
    read -p "重新安装将删除所有现有数据，是否继续? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消重新安装${NC}"
        return
    fi

    if [ -d "/opt/dendrite" ]; then
        BACKUP_DIR="/opt/dendrite_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo "备份现有配置到: $BACKUP_DIR"
        cp -r /opt/dendrite/config/* "$BACKUP_DIR/" 2>/dev/null || true
        cd /opt/dendrite
        docker-compose down -v || true
    fi

    rm -rf /opt/dendrite
    install_dendrite
}

# 主循环
while true; do
    show_menu
    read -p "请选择操作 [0-2]: " choice
    case $choice in
        1) install_dendrite; break ;;
        2) reinstall_dendrite; break ;;
        0) echo -e "${BLUE}退出脚本${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择，请重新输入${NC}" ;;
    esac
done
