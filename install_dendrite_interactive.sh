#!/bin/bash
set -e

# 日志和目录
LOG_DIR="/opt/dendrite/logs"
CONFIG_DIR="/opt/dendrite/config"
DATA_DIR="/opt/dendrite/data"
CERT_DIR="/opt/dendrite/certs"

mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$DATA_DIR/postgres" "$CERT_DIR"
exec > >(tee -a "$LOG_DIR/install.log") 2>&1

echo "======================================"
echo "Matrix Dendrite 一键部署脚本"
echo "======================================"

# 自动获取 VPS IP
VPS_IP=$(curl -s ifconfig.me)

# 交互式输入
read -p "请输入域名或 VPS IP (直接回车自动使用 VPS IP: $VPS_IP): " DOMAIN
DOMAIN=${DOMAIN:-$VPS_IP}

read -p "请输入 PostgreSQL 数据库密码: " DB_PASS
read -p "请输入管理员账号用户名: " ADMIN_USER
read -s -p "请输入管理员账号密码: " ADMIN_PASS
echo

# 系统检查
if ! grep -q "Ubuntu" /etc/os-release; then
    echo "脚本仅支持 Ubuntu 系统"
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

# 使用 OpenSSL 生成 Ed25519 密钥
echo "[2/7] 生成 Dendrite 私钥 (Ed25519)"
openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem"
chmod 600 "$CONFIG_DIR/matrix_key.pem"

# 创建完整配置文件
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
    connect: http://localhost:7777
    listen: http://0.0.0.0:7777

client_api:
  internal_api:
    connect: http://localhost:7771
    listen: http://0.0.0.0:7771
  external_api:
    listen: http://0.0.0.0:8071

federation_api:
  internal_api:
    connect: http://localhost:7772
    listen: http://0.0.0.0:7772
  external_api:
    listen: http://0.0.0.0:8072

key_server:
  internal_api:
    connect: http://localhost:7774
    listen: http://0.0.0.0:7774

media_api:
  internal_api:
    connect: http://localhost:7775
    listen: http://0.0.0.0:7775
  external_api:
    listen: http://0.0.0.0:8075
  base_path: /etc/dendrite/media_store

room_server:
  internal_api:
    connect: http://localhost:7773
    listen: http://0.0.0.0:7773

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

# 创建媒体存储目录
mkdir -p "$DATA_DIR/media_store"
chmod 755 "$DATA_DIR/media_store"

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
    restart: unless-stopped
EOF

# 启动服务
echo "[5/7] 启动服务"
cd /opt/dendrite
docker-compose down >/dev/null 2>&1 || true
docker-compose up -d

# 等待 Dendrite 启动
echo "等待服务启动..."
for i in {1..30}; do
    STATUS=$(docker-compose ps dendrite | grep dendrite | awk '{print $4}')
    if [[ "$STATUS" == "Up" ]]; then
        echo "✅ Dendrite 服务已启动"
        break
    fi
    echo "等待服务启动... ($i/30)"
    sleep 10
done

# 创建管理员账号
echo "[6/7] 创建管理员账号"
docker-compose exec -T dendrite \
    /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
    --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin || \
echo "⚠️ 管理员账号创建失败，可能已存在或服务未就绪"

# 配置 Nginx
echo "[7/7] 配置 Nginx"
NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
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

if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" || \
    echo "⚠️ Certbot 证书申请失败，请检查域名解析"
fi

echo "======================================"
echo "✅ 部署完成"
echo "访问地址: https://$DOMAIN"
echo "管理员账号: $ADMIN_USER"
echo "日志路径: $LOG_DIR"
echo "======================================"
echo "检查服务状态: cd /opt/dendrite && docker-compose ps"
echo "查看 Dendrite 日志: cd /opt/dendrite && docker-compose logs dendrite"
echo "查看 PostgreSQL 日志: cd /opt/dendrite && docker-compose logs postgres"
echo "重启服务: cd /opt/dendrite && docker-compose restart"
