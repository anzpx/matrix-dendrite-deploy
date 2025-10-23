#!/bin/bash
# ======================================
# Matrix Dendrite 部署脚本（修正版）
# ======================================

set -e

INSTALL_DIR="/opt/dendrite"
CONFIG_DIR="$INSTALL_DIR/config"
CERT_DIR="$INSTALL_DIR/certs"

# 创建目录
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# 用户输入
read -p "请输入域名或 VPS IP (回车自动使用 VPS IP): " DOMAIN
DOMAIN=${DOMAIN:-$(curl -s ifconfig.me)}

read -p "请输入 PostgreSQL 数据库密码 (回车随机生成): " DB_PASS
DB_PASS=${DB_PASS:-$(openssl rand -base64 12)}

read -p "请输入管理员账号用户名 (回车随机生成): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-user_$(openssl rand -hex 4)}

read -p "请输入管理员账号密码 (回车随机生成): " ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -base64 12)}

echo "使用配置如下:"
echo "域名/IP: $DOMAIN"
echo "数据库密码: $DB_PASS"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"

# --------------------------
# 安装依赖
# --------------------------
echo "[1/5] 安装依赖..."
apt update
apt install -y docker.io docker-compose curl nginx openssl python3-certbot-nginx dnsutils

# --------------------------
# 生成 PEM Ed25519 私钥
# --------------------------
KEY_FILE="$CONFIG_DIR/matrix_key.pem"
if [[ ! -f "$KEY_FILE" ]]; then
    echo "[2/5] 生成 Dendrite PEM 私钥..."
    ssh-keygen -t ed25519 -m PEM -f "$KEY_FILE" -N "" -q
    chmod 600 "$KEY_FILE"
    echo "PEM 私钥生成完成: $KEY_FILE"
else
    echo "[2/5] PEM 私钥已存在，跳过生成"
fi

# --------------------------
# 生成自签名证书
# --------------------------
CRT_FILE="$CERT_DIR/selfsigned.crt"
KEY_CERT_FILE="$CERT_DIR/selfsigned.key"

if [[ ! -f "$CRT_FILE" || ! -f "$KEY_CERT_FILE" ]]; then
    echo "[3/5] 生成自签名证书..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$KEY_CERT_FILE" \
        -out "$CRT_FILE" \
        -subj "/CN=$DOMAIN"
    echo "自签名证书生成完成: $CRT_FILE"
else
    echo "[3/5] 自签名证书已存在，跳过生成"
fi

# --------------------------
# 生成 Dendrite 配置文件
# --------------------------
CONFIG_FILE="$CONFIG_DIR/dendrite.yaml"
cat > "$CONFIG_FILE" <<EOF
server_name: "$DOMAIN"
private_key: "$KEY_FILE"
database:
  type: "postgres"
  user: "postgres"
  password: "$DB_PASS"
  host: "postgres"
  port: 5432
  name: "dendrite"
EOF
echo "[4/5] Dendrite 配置文件生成完成: $CONFIG_FILE"

# --------------------------
# Docker Compose 文件
# --------------------------
DOCKER_FILE="$INSTALL_DIR/docker-compose.yml"
cat > "$DOCKER_FILE" <<EOF
version: '3.7'

services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    restart: always
    environment:
      POSTGRES_PASSWORD: $DB_PASS
    volumes:
      - ./pgdata:/var/lib/postgresql/data

  dendrite:
    image: matrixdotorg/dendrite:latest
    container_name: dendrite_dendrite
    restart: always
    depends_on:
      - postgres
    volumes:
      - ./config:/etc/dendrite
    environment:
      DENDRITE_CONFIG: /etc/dendrite/dendrite.yaml
EOF
echo "[5/5] Docker Compose 文件生成完成: $DOCKER_FILE"

# --------------------------
# 启动服务
# --------------------------
docker-compose -f "$DOCKER_FILE" down || true
docker-compose -f "$DOCKER_FILE" up -d

echo "======================================"
echo "部署完成！"
echo "HTTP/HTTPS 地址: $DOMAIN"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"
echo "数据库密码: $DB_PASS"
echo "======================================"
