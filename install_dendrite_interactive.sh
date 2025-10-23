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

# 检查服务状态函数
check_service_status() {
    echo -e "${YELLOW}检查服务状态...${NC}"
    
    cd /opt/dendrite
    
    # 检查容器状态
    echo -e "${BLUE}容器状态:${NC}"
    docker-compose ps
    
    # 检查 PostgreSQL 日志
    echo -e "${BLUE}PostgreSQL 日志 (最后20行):${NC}"
    docker-compose logs postgres --tail=20
    
    # 检查 Dendrite 日志
    echo -e "${BLUE}Dendrite 日志 (最后30行):${NC}"
    docker-compose logs dendrite --tail=30
    
    # 检查端口监听
    echo -e "${BLUE}端口监听状态:${NC}"
    netstat -tlnp | grep -E ':(8008|8448|5432)' || echo "相关端口未监听"
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
    apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl
    systemctl enable --now docker

    # 检测域名解析
    DNS_IP=$(dig +short "$DOMAIN" | head -n1)
    USE_LETSENCRYPT="no"
    if [[ "$DNS_IP" == "$VPS_IP" ]] && [[ "$DOMAIN" != "$VPS_IP" ]]; then
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

    # 创建 Dendrite 配置文件（简化版本）
    echo "[3/7] 创建完整配置文件"
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
      interval: 5s
      timeout: 5s
      retries: 10

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
EOF

    # 启动服务
    echo "[5/7] 启动服务"
    cd /opt/dendrite
    docker-compose down -v || true
    docker-compose up -d

    # 等待服务启动（缩短等待时间）
    echo "等待服务启动（15秒）..."
    sleep 15

    # 快速检查服务状态
    echo "快速检查服务状态..."
    for i in {1..12}; do
        echo "检查尝试 ($i/12)..."
        
        # 检查容器是否运行
        if ! docker-compose ps | grep -q "Up"; then
            echo "容器未运行，等待 5 秒..."
            sleep 5
            continue
        fi
        
        # 尝试直接创建账号（不依赖健康检查）
        if docker-compose exec -T dendrite \
            /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
            --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin 2>/dev/null; then
            echo "✅ 管理员账号创建成功"
            break
        else
            echo "账号创建失败 ($i/12)，等待 5 秒后重试..."
            sleep 5
        fi
        
        if [ $i -eq 6 ]; then
            echo -e "${YELLOW}中间检查点 - 当前服务状态:${NC}"
            docker-compose ps
            docker-compose logs dendrite --tail=10
        fi
    done

    # 最终检查
    if docker-compose exec -T dendrite \
        /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
        --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin 2>/dev/null; then
        echo "✅ 管理员账号创建成功"
    else
        echo -e "${YELLOW}⚠️ 管理员账号创建失败${NC}"
        check_service_status
        echo -e "${YELLOW}请稍后手动创建管理员账号:${NC}"
        echo "cd /opt/dendrite && docker-compose exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml --username \"$ADMIN_USER\" --password \"$ADMIN_PASS\" --admin"
    fi

    # 配置 Nginx（简化版本）
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
        echo "配置 Nginx HTTP（无 SSL）"
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
    fi

    ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

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
        echo "HTTP 地址: http://$DOMAIN"
    fi
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "数据库密码: $DB_PASS"
    echo "======================================"
    
    # 最终状态检查
    check_service_status
    
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
