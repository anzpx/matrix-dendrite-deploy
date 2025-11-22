#!/bin/bash
set -e

echo "============================="
echo "  一键部署 Matrix Dendrite "
echo "============================="

# 自动获取 VPS 公网 IP
VPS_IP=$(ip -4 addr show ens3 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "检测到 VPS 公网 IP: $VPS_IP"

# 部署目录
DEPLOY_DIR="/opt/dendrite-deploy"
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# 随机生成 PostgreSQL 密码
POSTGRES_PASSWORD=$(openssl rand -base64 12)
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# 创建空目录和密钥文件占位
mkdir -p media_store
touch matrix_key.pem

# 创建 docker-compose.yml
cat > docker-compose.yml <<EOF
version: "3.9"
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
      - $DEPLOY_DIR/dendrite.yaml:/dendrite.yaml:ro
      - $DEPLOY_DIR/matrix_key.pem:/matrix_key.pem:ro
      - $DEPLOY_DIR/media_store:/media_store
volumes:
  postgres_data:
EOF

# 创建最小可用 dendrite.yaml
cat > dendrite.yaml <<EOF
server_name: "$VPS_IP"
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

# 启动 Dendrite 容器
docker compose up -d

# 查看日志
docker logs -f dendrite
