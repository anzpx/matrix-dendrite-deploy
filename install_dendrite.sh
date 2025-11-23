#!/bin/bash
set -e

echo "======================================"
echo " Matrix Dendrite + Caddy + Element-Web"
echo "       全自动一键部署脚本"
echo "======================================"

# -------------------------------
# 获取公网 IP
# -------------------------------
PUBLIC_IP=$(curl -fsS ifconfig.me || hostname -I | awk '{print $1}')
if [ -z "$PUBLIC_IP" ]; then
    echo "无法获取公网 IP，请手动输入"
    read -p "请输入你的服务器公网 IP 或域名: " PUBLIC_IP
fi

read -p "请输入域名（可直接回车使用自动获取 IP ${PUBLIC_IP}）: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-$PUBLIC_IP}
echo "使用域名/IP: $SERVER_NAME"

# ===============================
# 创建目录结构
# ===============================
INSTALL_DIR="/opt/dendrite"
WEB_DIR="/opt/element-web"
CADDY_DIR="/opt/caddy"
mkdir -p $INSTALL_DIR/config $INSTALL_DIR/pgdata
mkdir -p $WEB_DIR
mkdir -p $CADDY_DIR

# ===============================
# 安装 Docker
# ===============================
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
fi

if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
    curl -L "https://github.com/docker/compose/releases/download/v2.27.2/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# ===============================
# PostgreSQL 密码
# ===============================
PGPASS=$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')

# ===============================
# 生成 docker-compose.yml
# ===============================
cat > /opt/docker-compose.yml <<EOF
version: "3.8"
services:

  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: "${PGPASS}"
      POSTGRES_DB: dendrite
    volumes:
      - /opt/dendrite/pgdata:/var/lib/postgresql/data

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    restart: unless-stopped
    depends_on:
      - postgres
    volumes:
      - /opt/dendrite/config:/etc/dendrite

  element-web:
    image: vectorim/element-web
    restart: unless-stopped
    volumes:
      - /opt/element-web/config.json:/app/config.json

  caddy:
    image: caddy:2.7
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/caddy/Caddyfile:/etc/caddy/Caddyfile
      - /opt/caddy/data:/data
      - /opt/caddy/config:/config
EOF

# ===============================
# 生成 Caddyfile（自动 HTTPS + 反向代理）
# ===============================
cat > $CADDY_DIR/Caddyfile <<EOF
${SERVER_NAME} {
    encode gzip
    tls {
        issuer acme
    }

    @element path /
    reverse_proxy @element element-web:80

    handle_path /_matrix/* {
        reverse_proxy dendrite:8008
    }

    handle_path /_matrix/federation/* {
        reverse_proxy dendrite:8448
    }
}
EOF

# ===============================
# 生成 Element Web config.json
# ===============================
cat > $WEB_DIR/config.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${SERVER_NAME}",
      "server_name": "${SERVER_NAME}"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "brand": "MyMatrixChat",
  "default_theme": "dark"
}
EOF

# ===============================
# 清理旧私钥 & 生成新私钥 + TLS
# ===============================
rm -f $INSTALL_DIR/config/matrix_key.pem $INSTALL_DIR/config/server.crt $INSTALL_DIR/config/server.key

docker run --rm --entrypoint="/usr/bin/generate-keys" \
  -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
  -private-key /mnt/matrix_key.pem \
  -tls-cert /mnt/server.crt \
  -tls-key /mnt/server.key

# ===============================
# 生成 dendrite.yaml
# ===============================
docker run --rm --entrypoint="/usr/bin/generate-config" \
  -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
  -dir /var/dendrite \
  -db "postgres://dendrite:${PGPASS}@postgres/dendrite?sslmode=disable" \
  -server "${SERVER_NAME}" \
  > "$INSTALL_DIR/config/dendrite.yaml"

sed -i 's#/var/dendrite#/etc/dendrite#g' "$INSTALL_DIR/config/dendrite.yaml"

# ===============================
# 启动所有服务
# ===============================
docker compose -f /opt/docker-compose.yml up -d

echo "======================================"
echo "        Matrix 全套服务部署成功"
echo "======================================"
echo "访问 Element Web:"
echo "   👉 https://${SERVER_NAME}"
echo "客户端 API:"
echo "   https://${SERVER_NAME}/_matrix"
echo "联邦 API:"
echo "   https://${SERVER_NAME}/_matrix/federation"
echo
echo "查看日志:"
echo "   docker compose -f /opt/docker-compose.yml logs -f"
echo "======================================"
