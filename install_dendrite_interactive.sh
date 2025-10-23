#!/bin/bash
# ======================================
# Matrix Dendrite 一键部署脚本
# ======================================

set -e

# -----------------------------
# 用户输入
# -----------------------------
read -p "请输入域名或 VPS IP (回车使用 localhost): " DOMAIN
DOMAIN=${DOMAIN:-localhost}

read -p "请输入 PostgreSQL 用户名 (回车使用 dendrite): " PGUSER
PGUSER=${PGUSER:-dendrite}

read -s -p "请输入 PostgreSQL 密码 (回车随机生成): " PGPASS
echo
if [ -z "$PGPASS" ]; then
    PGPASS=$(openssl rand -base64 16)
fi

# 管理员账号
read -p "请输入管理员用户名 (回车随机生成): " ADMINUSER
ADMINUSER=${ADMINUSER:-admin_$(openssl rand -hex 4)}

read -s -p "请输入管理员密码 (回车随机生成): " ADMINPASS
echo
if [ -z "$ADMINPASS" ]; then
    ADMINPASS=$(openssl rand -base64 12)
fi

# -----------------------------
# 安装依赖
# -----------------------------
echo "[INFO] 安装依赖..."
apt update
apt install -y curl docker.io nginx openssl

# 安装 Docker Compose V2
if ! command -v docker-compose &>/dev/null; then
    echo "[INFO] 安装 Docker Compose V2..."
    curl -SL https://github.com/docker/compose/releases/download/v2.28.2/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# -----------------------------
# 创建目录
# -----------------------------
echo "[INFO] 创建数据目录..."
mkdir -p /opt/dendrite/data/db /opt/dendrite/data/media_store /opt/dendrite/config

# -----------------------------
# 生成私钥
# -----------------------------
KEY_FILE="/opt/dendrite/config/matrix_key.pem"
if [ ! -f "$KEY_FILE" ]; then
    echo "[INFO] 生成 Dendrite 私钥..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q
fi

# -----------------------------
# 生成自签名证书
# -----------------------------
CERT_DIR="/opt/dendrite/certs"
mkdir -p $CERT_DIR
if [ ! -f "$CERT_DIR/selfsigned.crt" ]; then
    echo "[INFO] 生成自签名证书..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout $CERT_DIR/selfsigned.key \
        -out $CERT_DIR/selfsigned.crt \
        -subj "/CN=$DOMAIN"
fi

# -----------------------------
# 生成 dendrite.yaml
# -----------------------------
echo "[INFO] 生成 dendrite.yaml..."
cat > /opt/dendrite/config/dendrite.yaml <<EOF
version: 2
global:
  server_name: "$DOMAIN"
  private_key: "/etc/dendrite/matrix_key.pem"
  database:
    connection_string: "postgres://$PGUSER:$PGPASS@db/dendrite?sslmode=disable"
  media_api:
    base_path: "/var/dendrite/media_store"
EOF

# -----------------------------
# 生成 docker-compose.yml
# -----------------------------
echo "[INFO] 生成 docker-compose.yml..."
cat > /opt/dendrite/docker-compose.yml <<EOF
version: "3.8"
services:
  db:
    image: postgres:14
    container_name: dendrite_db
    restart: always
    environment:
      POSTGRES_USER: $PGUSER
      POSTGRES_PASSWORD: $PGPASS
      POSTGRES_DB: dendrite
    volumes:
      - ./data/db:/var/lib/postgresql/data
    networks:
      - dendrite_network

  dendrite:
    image: ghcr.io/matrix-org/dendrite-monolith:latest
    container_name: dendrite
    restart: always
    depends_on:
      - db
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config/matrix_key.pem:/etc/dendrite/matrix_key.pem:ro
      - ./config/dendrite.yaml:/etc/dendrite/dendrite.yaml:ro
      - ./data/media_store:/var/dendrite/media_store
    networks:
      - dendrite_network
    command: ["/usr/bin/dendrite"]

networks:
  dendrite_network:
    driver: bridge
EOF

# -----------------------------
# 启动容器
# -----------------------------
echo "[INFO] 启动容器..."
cd /opt/dendrite
docker-compose down || true
docker-compose up -d

echo "======================================"
echo "部署完成！访问信息："
echo "HTTP: http://$DOMAIN:8008"
echo "HTTPS: https://$DOMAIN:8448"
echo "管理员账号: $ADMINUSER"
echo "管理员密码: $ADMINPASS"
echo "PostgreSQL 用户: $PGUSER"
echo "PostgreSQL 密码: $PGPASS"
echo "======================================"
docker-compose ps
