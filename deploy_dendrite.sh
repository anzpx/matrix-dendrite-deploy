#!/bin/bash
set -e

# ================================
# Matrix Dendrite 一键部署脚本
# 自动获取 VPS 公网 IP，生成 PostgreSQL 密码
# 带错误检测和日志输出
# ================================

echo "===== Matrix Dendrite 部署开始 ====="

# 自动获取 VPS 公网 IP
IP=$(curl -s ifconfig.me || curl -s icanhazip.com)
if [[ -z "$IP" ]]; then
    echo "获取公网 IP 失败，请手动输入:"
    read -rp "VPS 公网 IP: " IP
fi
echo "检测到 VPS 公网 IP: $IP"

# 安装必要软件
echo "安装 Docker、docker-compose、curl、openssl..."
apt update
apt install -y docker.io docker-compose curl openssl || {
    echo "软件安装失败，请检查网络或源"
    exit 1
}

# 启动 Docker
echo "启动 Docker 服务..."
systemctl enable docker
systemctl start docker || {
    echo "Docker 启动失败，请检查 systemctl 状态"
    exit 1
}

# 创建部署目录
DEPLOY_DIR=/opt/dendrite-deploy
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# 随机生成 PostgreSQL 密码
POSTGRES_PASSWORD=$(openssl rand -base64 12)
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# 创建必要目录和空文件
mkdir -p media_store
touch matrix_key.pem

# 创建 docker-compose.yml
cat > docker-compose.yml <<EOF
services:
  dendrite_postgres:
    image: postgres:15
    container_name: dendrite_postgres
    environment:
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DB: dendrite
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      retries: 5

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    container_name: dendrite
    depends_on:
      dendrite_postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
      - "8800:8800"
    volumes:
      - $DEPLOY_DIR/dendrite.yaml:/dendrite.yaml
      - $DEPLOY_DIR/matrix_key.pem:/matrix_key.pem
      - $DEPLOY_DIR/media_store:/media_store

volumes:
  postgres_data:
EOF

# 创建 dendrite.yaml
cat > dendrite.yaml <<EOF
server_name: "$IP"
pid_file: "/var/run/dendrite.pid"
report_stats: false
private_key_path: "./matrix_key.pem"

logging:
  level: info

database:
  connection_string: "postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite?sslmode=disable"

http_api:
  listen: "0.0.0.0:8008"
  enable_metrics: true

federation_api:
  listen: "0.0.0.0:8448"

media_api:
  base_path: "./media_store"
  listen: "0.0.0.0:8800"

room_server:
  database:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite_roomserver?sslmode=disable"

account_server:
  database:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite_accounts?sslmode=disable"

sync_api:
  database:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite_sync?sslmode=disable"
EOF

# 启动容器
echo "启动 Dendrite 容器..."
docker compose up -d || {
    echo "Docker 容器启动失败，请检查 docker compose 配置"
    exit 1
}

# 等待容器健康
echo "等待 PostgreSQL 健康..."
for i in {1..10}; do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' dendrite_postgres 2>/dev/null || echo unknown)
    if [[ "$STATUS" == "healthy" ]]; then
        echo "PostgreSQL 已健康"
        break
    fi
    echo "等待中... ($i/10)"
    sleep 3
done

# 检查 dendrite 容器状态
DENDRITE_STATUS=$(docker inspect -f '{{.State.Status}}' dendrite)
if [[ "$DENDRITE_STATUS" != "running" ]]; then
    echo "Dendrite 容器未启动成功，请查看日志:"
    docker logs dendrite
    exit 1
fi

echo "===== 部署完成 ====="
echo "查看日志：docker logs -f dendrite"
docker logs -f dendrite
