#!/usr/bin/env bash
set -e

# ===============================
# Matrix Dendrite 一键部署脚本
# ===============================

# 配置变量
DENDRITE_DIR="/opt/dendrite"
CONFIG_DIR="$DENDRITE_DIR/config"
DATA_DIR="$DENDRITE_DIR/data"
MEDIA_DIR="$DATA_DIR/media_store"
DB_DIR="$DATA_DIR/db"

# 提示用户输入
read -rp "请输入域名或 VPS IP (回车使用 localhost): " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-localhost}

read -rp "请输入 PostgreSQL 用户名 (回车使用 dendrite): " DB_USER
DB_USER=${DB_USER:-dendrite}

read -rp "请输入 PostgreSQL 密码 (回车随机生成): " DB_PASS
if [ -z "$DB_PASS" ]; then
    DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
fi

read -rp "请输入管理员用户名 (回车随机生成): " ADMIN_USER
if [ -z "$ADMIN_USER" ]; then
    ADMIN_USER="admin_$(head /dev/urandom | tr -dc a-f0-9 | head -c 10)"
fi

read -rp "请输入管理员密码 (回车随机生成): " ADMIN_PASS
if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
fi

echo "======================================"
echo "配置如下:"
echo "域名/IP: $SERVER_NAME"
echo "数据库用户: $DB_USER"
echo "数据库密码: $DB_PASS"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"
echo "======================================"

# 创建目录
mkdir -p "$CONFIG_DIR" "$MEDIA_DIR" "$DB_DIR"

# 安装依赖
apt update
apt install -y curl docker.io nginx openssl python3-certbot-nginx git

# 安装 Docker Compose
if ! command -v docker-compose &>/dev/null; then
    echo "[INFO] 安装 Docker Compose..."
    curl -SL https://github.com/docker/compose/releases/download/v2.28.2/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# 生成 Dendrite 私钥
if [ ! -f "$CONFIG_DIR/matrix_key.pem" ]; then
    echo "[INFO] 生成 Dendrite 私钥..."
    ssh-keygen -t ed25519 -f "$CONFIG_DIR/matrix_key.pem" -N ""
fi

# 生成自签名证书
echo "[INFO] 生成自签名证书..."
mkdir -p "$DENDRITE_DIR/certs"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$DENDRITE_DIR/certs/selfsigned.key" \
    -out "$DENDRITE_DIR/certs/selfsigned.crt" \
    -subj "/CN=$SERVER_NAME"

# 生成 dendrite.yaml
cat > "$CONFIG_DIR/dendrite.yaml" << EOF
version: 2
global:
  server_name: "$SERVER_NAME"
  private_key: "/etc/dendrite/matrix_key.pem"
  database:
    connection_string: "postgres://$DB_USER:$DB_PASS@db/$DB_USER?sslmode=disable"
  media_api:
    base_path: "/var/dendrite/media_store"
EOF

# 生成 docker-compose.yml
cat > "$DENDRITE_DIR/docker-compose.yml" << EOF
version: "3.9"
services:
  db:
    image: postgres:14
    container_name: dendrite_db
    environment:
      POSTGRES_USER: $DB_USER
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: $DB_USER
    volumes:
      - $DB_DIR:/var/lib/postgresql/data
    restart: unless-stopped

  dendrite:
    image: ghcr.io/matrix-org/dendrite-monolith:latest
    container_name: dendrite
    depends_on:
      - db
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - $CONFIG_DIR:/etc/dendrite
      - $MEDIA_DIR:/var/dendrite/media_store
    restart: unless-stopped
EOF

# 启动容器
echo "[INFO] 启动容器..."
docker-compose -f "$DENDRITE_DIR/docker-compose.yml" down || true
docker-compose -f "$DENDRITE_DIR/docker-compose.yml" up -d

# 显示状态
docker ps

echo "======================================"
echo "部署完成!"
echo "访问 HTTP/HTTPS 地址: $SERVER_NAME:8008 / $SERVER_NAME:8448"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"
echo "数据库用户名: $DB_USER"
echo "数据库密码: $DB_PASS"
echo "======================================"
