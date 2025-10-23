#!/bin/bash
set -e

LOG_DIR="/opt/dendrite/logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/install.log") 2>&1

echo "======================================"
echo "Matrix Dendrite 自动证书部署（交互式）"
echo "======================================"

# 交互输入参数
read -p "请输入域名或 VPS IP: " DOMAIN
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
echo "[1/6] 安装 Docker / Docker Compose / Nginx / Certbot"
apt update -y
apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl
systemctl enable --now docker

# 检测域名解析
VPS_IP=$(curl -s ifconfig.me)
DNS_IP=$(dig +short $DOMAIN | head -n1)
USE_LETSENCRYPT="no"

if [[ "$DNS_IP" == "$VPS_IP" ]]; then
    echo "✅ 域名解析正确，启用 Let’s Encrypt"
    USE_LETSENCRYPT="yes"
else
    echo "⚠️ 域名未解析到 VPS 公网 IP，将使用自签名证书"
    DOMAIN="$VPS_IP"
fi

# 创建目录
mkdir -p /opt/dendrite/{config,data/postgres,certs}

# Docker Compose 文件
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

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    depends_on:
      - postgres
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
    environment:
      - SERVER_NAME=$DOMAIN
      - DB_SOURCE=postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable
    command:
      - "/usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml"
    restart: unless-stopped
EOF

# 生成密钥和配置
docker run --rm -v /opt/dendrite/config:/mnt matrixdotorg/dendrite-monolith:latest     /usr/bin/generate-keys -private-key /mnt/matrix_key.pem

docker run --rm -v /opt/dendrite/config:/mnt matrixdotorg/dendrite-monolith:latest     /usr/bin/generate-config -dir /var/dendrite/     -db postgres://dendrite:$DB_PASS@postgres/dendrite?sslmode=disable     -server $DOMAIN > /opt/dendrite/config/dendrite.yaml

# 启动 Docker
docker-compose -f /opt/dendrite/docker-compose.yml up -d

# 创建管理员账号
docker exec -it dendrite-monolith   /usr/bin/create-account -config /etc/dendrite/dendrite.yaml   -username $ADMIN_USER -password $ADMIN_PASS --admin || echo "管理员账号可能已存在"

# 配置 Nginx + 证书
NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
mkdir -p /opt/dendrite/certs

if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
    echo "[7/7] 配置 Nginx + Let’s Encrypt"
    cat > $NGINX_CONF <<NGX
server {
    server_name $DOMAIN;
    access_log $LOG_DIR/nginx_access.log;
    error_log $LOG_DIR/nginx_error.log;

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
    nginx -t && systemctl restart nginx
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || echo "Certbot 证书申请失败"
else
    echo "[7/7] 配置 Nginx + 自签名证书"
    SSL_KEY="/opt/dendrite/certs/selfsigned.key"
    SSL_CRT="/opt/dendrite/certs/selfsigned.crt"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048         -keyout $SSL_KEY -out $SSL_CRT         -subj "/CN=$DOMAIN"
    cat > $NGINX_CONF <<NGX
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $SSL_CRT;
    ssl_certificate_key $SSL_KEY;

    access_log $LOG_DIR/nginx_access.log;
    error_log $LOG_DIR/nginx_error.log;

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
    nginx -t && systemctl restart nginx
    echo "⚠️ 使用自签名证书，浏览器可能显示不安全"
fi

echo "======================================"
echo "✅ 部署完成"
echo "访问地址: http://$DOMAIN:8008"
if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
    echo "HTTPS 地址: https://$DOMAIN"
else
    echo "HTTPS 地址（自签名证书）: https://$DOMAIN"
fi
echo "管理员账号: $ADMIN_USER"
echo "日志路径: $LOG_DIR"
echo "======================================"
