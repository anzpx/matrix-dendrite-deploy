#!/bin/bash
set -e

echo "======================================"
echo "      Matrix Dendrite 一键部署脚本"
echo "======================================"

# ----------------------------------------------------------
# 输入参数
# ----------------------------------------------------------
read -p "请输入域名或 VPS IP（回车自动使用公网 IP）: " SERVER_NAME
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME=$(curl -fsS ifconfig.me || hostname -f)
fi
echo "使用 Server Name: $SERVER_NAME"

read -p "请输入管理员用户名（默认 admin）: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "请输入管理员密码（回车随机生成）: " ADMIN_PASS
if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)
fi

echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"

# ----------------------------------------------------------
# 目录设置
# ----------------------------------------------------------
INSTALL_DIR="/opt/dendrite"
CONFIG_DIR="$INSTALL_DIR/config"
PGDATA_DIR="$INSTALL_DIR/pgdata"

mkdir -p "$CONFIG_DIR" "$PGDATA_DIR"
echo "目录已创建: $INSTALL_DIR"

# ----------------------------------------------------------
# 安装 Docker
# ----------------------------------------------------------
echo "检查 Docker..."
if ! command -v docker &>/dev/null; then
    echo "Docker 未安装，开始安装..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
else
    echo "Docker 已安装"
fi

echo "检查 Docker Compose..."
if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    echo "安装 Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/download/v2.27.2/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo "Docker Compose 已安装"
fi

# ----------------------------------------------------------
# 停止旧容器并清理
# ----------------------------------------------------------
cd "$INSTALL_DIR"
echo "清理旧容器…"
docker compose down || true

# ----------------------------------------------------------
# 生成 Postgres 密码
# ----------------------------------------------------------
PGPASS=$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
echo "Postgres 密码生成成功"

# ----------------------------------------------------------
# 生成 docker-compose.yml（官方推荐结构）
# ----------------------------------------------------------
cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
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
      - ./pgdata:/var/lib/postgresql/data

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    restart: unless-stopped
    depends_on:
      - postgres
    volumes:
      - ./config:/etc/dendrite
    ports:
      - "8008:8008"
      - "8448:8448"
EOF

echo "docker-compose.yml 已生成"

# ----------------------------------------------------------
# 强制删除旧的私钥和 TLS（避免覆盖失败）
# ----------------------------------------------------------
rm -f "$CONFIG_DIR/matrix_key.pem" "$CONFIG_DIR/server.crt" "$CONFIG_DIR/server.key"

# ----------------------------------------------------------
# 生成私钥 + 自签 TLS
# ----------------------------------------------------------
echo "生成私钥与 TLS 证书..."
docker run --rm --entrypoint="/usr/bin/generate-keys" \
    -v "$CONFIG_DIR":/mnt matrixdotorg/dendrite-monolith:latest \
    -private-key /mnt/matrix_key.pem \
    -tls-cert /mnt/server.crt \
    -tls-key /mnt/server.key

# ----------------------------------------------------------
# 生成 dendrite.yaml 配置
# ----------------------------------------------------------
echo "生成 dendrite.yaml ..."

docker run --rm --entrypoint="/usr/bin/generate-config" \
    -v "$CONFIG_DIR":/mnt matrixdotorg/dendrite-monolith:latest \
    -dir /var/dendrite/ \
    -db "postgres://dendrite:${PGPASS}@postgres/dendrite?sslmode=disable" \
    -server "${SERVER_NAME}" \
    > "$CONFIG_DIR/dendrite.yaml"

sed -i 's#/var/dendrite#/etc/dendrite#g' "$CONFIG_DIR/dendrite.yaml"

echo "配置文件生成成功"

# ----------------------------------------------------------
# 启动 Dendrite
# ----------------------------------------------------------
docker compose up -d

echo "======================================"
echo "Dendrite 部署完成！"
echo "访问 Client API: http://${SERVER_NAME}:8008"
echo "访问 Federation API: http://${SERVER_NAME}:8448"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"
echo
echo "查看日志: docker compose logs -f dendrite"
echo "======================================"
