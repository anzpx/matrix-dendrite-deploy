#!/bin/bash
set -e

# ===============================
# Matrix Dendrite 一键部署脚本
# 适配 Ubuntu 22.04 / Docker 环境
# ===============================

LOG_DIR="/opt/dendrite/logs"
CONFIG_DIR="/opt/dendrite/config"
DATA_DIR="/opt/dendrite/data"
CERT_DIR="/opt/dendrite/certs"

mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$DATA_DIR/postgres" "$CERT_DIR"
exec > >(tee -a "$LOG_DIR/install.log") 2>&1

echo "======================================"
echo "Matrix Dendrite 一键部署脚本"
echo "======================================"

read -p "请输入域名或 VPS IP: " DOMAIN
read -p "请输入 PostgreSQL 数据库密码: " DB_PASS
read -p "请输入管理员账号用户名: " ADMIN_USER
read -s -p "请输入管理员账号密码: " ADMIN_PASS
echo

if ! grep -q "Ubuntu" /etc/os-release; then
    echo "❌ 脚本仅支持 Ubuntu"
    exit 1
fi

echo "[1/7] 安装依赖..."
apt update -y
apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl
systemctl enable --now docker

# ===============================
# 检查域名解析
# ===============================
VPS_IP=$(curl -s ifconfig.me)
DNS_IP=$(dig +short "$DOMAIN" | head -n1)
USE_LETSENCRYPT="no"
if [[ "$DNS_IP" == "$VPS_IP" ]]; then
    echo "✅ 域名解析正确 ($DNS_IP == $VPS_IP)，使用 Let's Encrypt"
    USE_LETSENCRYPT="yes"
else
    echo "⚠️ 域名未解析到 VPS，将使用自签名证书"
    DOMAIN="$VPS_IP"
fi

# ===============================
# 生成密钥
# ===============================
echo "[2/7] 生成 Dendrite 密钥..."
openssl genrsa -out "$CONFIG_DIR/matrix_key.pem" 2048

# ===============================
# 生成 dendrite.yaml
# ===============================
echo "[3/7] 创建配置文件..."
cat > "$CONFIG_DIR/dendrite.yaml" <<EOF
global:
  server_name: $DOMAIN
  private_key: /etc/dendrite/matrix_key.pem
  well_known_server_name: https://$DOMAIN

database:
  connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

media_api:
  base_path: /etc/dendrite/media_store

logging:
  - type: std
    level: info
EOF

chmod 644 "$CONFIG_DIR/dendrite.yaml"

# ===============================
# 创建 docker-compose.yml
# ===============================
echo "[4/7] 创建 Docker Compose 配置..."
cat > /opt/dendrite/docker-compose.yml <<EOF
version: '3.7'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: dendrite
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite -d dendrite"]
      interval: 10s
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
    command: >
      /usr/bin/dendrite-monolith
      --config /etc/dendrite/dendrite.yaml
      --http-bind-address 0.0.0.0:8008
      --https-bind-address 0.0.0.0:8448
    restart: unless-stopped
EOF

# ===============================
# 启动 Dendrite
# ===============================
echo "[5/7] 启动 Dendrite 服务..."
cd /opt/dendrite
docker-compose down >/dev/null 2>&1 || true
docker-compose up -d

echo "等待容器启动..."
sleep 20
docker-compose ps

# ===============================
# 创建管理员账号
# ===============================
echo "[6/7] 创建管理员账号..."
if docker-compose exec -T dendrite \
  /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
  --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin >/dev/null 2>&1; then
  echo "✅ 管理员账号创建成功"
else
  echo "⚠️ 创建失败，稍后可手动执行以下命令："
  echo "cd /opt/dendrite && docker-compose exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml --username $ADMIN_USER --password '$ADMIN_PASS' --admin"
fi

# ===============================
# 配置 Nginx
# ===============================
echo "[7/7] 配置 Nginx..."

NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
    cat > "$NGINX_CONF" <<NGX
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
    SSL_KEY="$CERT_DIR/selfsigned.key"
    SSL_CRT="$CERT_DIR/selfsigned.crt"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_KEY" -out "$SSL_CRT" -subj "/CN=$DOMAIN" >/dev/null 2>&1
    cat > "$NGINX_CONF" <<NGX
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

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
  certbot --nginx -d "$DOMAIN" --agree-tos -m admin@$DOMAIN --non-interactive || true
fi

echo "======================================"
echo "✅ 部署完成"
echo "访问地址: https://$DOMAIN"
echo "管理员账号: $ADMIN_USER"
echo "日志路径: $LOG_DIR"
echo "======================================"
