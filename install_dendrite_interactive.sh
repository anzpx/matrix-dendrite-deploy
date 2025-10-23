#!/bin/bash
# ======================================
# Matrix Dendrite 自动部署脚本（最终优化版）
# 兼容 Ubuntu 22.04+
# 使用 vectorim/dendrite 镜像（官方推荐）
# ======================================

BASE_DIR="/opt/dendrite"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
MEDIA_DIR="$DATA_DIR/media_store"
CERT_DIR="$BASE_DIR/certs"
DOCKER_COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DENDRITE_CONFIG="$CONFIG_DIR/dendrite.yaml"
KEY_FILE="$CONFIG_DIR/matrix_key.pem"
SELF_SIGNED_CERT="$CERT_DIR/selfsigned.crt"
SELF_SIGNED_KEY="$CERT_DIR/selfsigned.key"

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$MEDIA_DIR" "$CERT_DIR"

# 生成随机密码函数
random_pass() {
    openssl rand -base64 16
}

# 主菜单
echo "======================================"
echo "    Matrix Dendrite 部署脚本"
echo "======================================"
echo "1. 安装 Dendrite"
echo "2. 重新安装 Dendrite"
echo "0. 退出"
echo "======================================"
read -rp "请选择操作 [0-2]: " choice

case "$choice" in
    0)
        echo "退出脚本"
        exit 0
        ;;
    2)
        read -rp "确认重新安装将删除所有现有数据 (y/N): " yn
        if [[ "$yn" != "y" && "$yn" != "Y" ]]; then
            echo "取消重装"
            exit 0
        fi
        echo "[INFO] 停止并删除旧容器"
        docker-compose -f "$DOCKER_COMPOSE_FILE" down
        echo "[INFO] 清理旧数据"
        rm -rf "$DATA_DIR"/*
        ;;
esac

# 读取配置
read -rp "请输入域名或 VPS IP (回车使用 localhost): " DOMAIN
DOMAIN=${DOMAIN:-localhost}

read -rp "请输入 PostgreSQL 用户名 (回车使用 dendrite): " PGUSER
PGUSER=${PGUSER:-dendrite}

read -rp "请输入 PostgreSQL 密码 (回车随机生成): " PGPASS
PGPASS=${PGPASS:-$(random_pass)}

read -rp "请输入管理员用户名 (回车随机生成): " ADMINUSER
ADMINUSER=${ADMINUSER:-admin_$(openssl rand -hex 3)}

read -rp "请输入管理员密码 (回车随机生成): " ADMINPASS
ADMINPASS=${ADMINPASS:-$(random_pass)}

echo "======================================"
echo "域名/IP: $DOMAIN"
echo "PostgreSQL 用户: $PGUSER"
echo "PostgreSQL 密码: $PGPASS"
echo "管理员账号: $ADMINUSER"
echo "管理员密码: $ADMINPASS"
echo "======================================"

# 安装依赖
echo "[INFO] 安装依赖..."
apt update
apt install -y docker.io docker-compose curl openssl nginx certbot python3-certbot-nginx dnsutils

# 检查 Docker 服务
systemctl enable docker
systemctl restart docker

# 生成私钥
if [[ ! -f "$KEY_FILE" ]]; then
    echo "[INFO] 生成 Dendrite 私钥..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
else
    echo "[INFO] PEM 私钥已存在: $KEY_FILE"
fi

# 检查私钥合法性
if ! grep -q "PRIVATE KEY" "$KEY_FILE"; then
    echo "[WARN] 私钥文件损坏，重新生成..."
    rm -f "$KEY_FILE"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
fi

# 生成自签名证书
if [[ ! -f "$SELF_SIGNED_CERT" || ! -f "$SELF_SIGNED_KEY" ]]; then
    echo "[INFO] 生成自签名 SSL 证书..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SELF_SIGNED_KEY" -out "$SELF_SIGNED_CERT" \
        -subj "/CN=$DOMAIN"
else
    echo "[INFO] 自签名证书已存在"
fi

# 生成 Dendrite 配置
echo "[INFO] 生成 Dendrite 配置..."
cat > "$DENDRITE_CONFIG" <<EOF
server_name: "$DOMAIN"
private_key: "/etc/dendrite/matrix_key.pem"
database:
  type: postgres
  connection_string: "postgres://$PGUSER:$PGPASS@postgres/dendrite?sslmode=disable"
media:
  base_path: /media_store
EOF

# 生成 Docker Compose
echo "[INFO] 生成 docker-compose.yml..."
cat > "$DOCKER_COMPOSE_FILE" <<EOF
version: '3.7'

services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    environment:
      POSTGRES_USER: "$PGUSER"
      POSTGRES_PASSWORD: "$PGPASS"
      POSTGRES_DB: dendrite
    volumes:
      - $DATA_DIR/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $PGUSER"]
      interval: 5s
      retries: 5

  dendrite:
    image: vectorim/dendrite:latest
    container_name: dendrite_dendrite
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - $CONFIG_DIR:/etc/dendrite
      - $MEDIA_DIR:/media_store
    ports:
      - "8008:8008"
      - "8448:8448"
    restart: unless-stopped
EOF

# 生成 Nginx 配置
echo "[INFO] 生成 Nginx 配置..."
cat > /etc/nginx/sites-available/dendrite.conf <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $SELF_SIGNED_CERT;
    ssl_certificate_key $SELF_SIGNED_KEY;

    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

ln -sf /etc/nginx/sites-available/dendrite.conf /etc/nginx/sites-enabled/dendrite.conf
nginx -t && systemctl restart nginx

# 启动容器
echo "[INFO] 启动 Dendrite 容器..."
docker-compose -f "$DOCKER_COMPOSE_FILE" up -d

# 健康检查
echo "[INFO] 检查 Dendrite 启动状态..."
sleep 8
docker ps | grep dendrite && echo "[OK] Dendrite 启动成功" || echo "[ERROR] 容器启动异常，请检查 docker logs dendrite_dendrite"

echo "======================================"
echo "✅ Dendrite 部署完成！"
echo "访问地址: https://$DOMAIN"
echo "管理员账号: $ADMINUSER"
echo "管理员密码: $ADMINPASS"
echo "数据库密码: $PGPASS"
echo "配置路径: $BASE_DIR"
echo "======================================"
