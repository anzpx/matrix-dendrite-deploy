#!/bin/bash
set -e

echo "======================================"
echo " Ubuntu 22.04 Dendrite 一键部署脚本 "
echo "======================================"

# 1. 更新系统
sudo apt update -y
sudo apt upgrade -y

# 2. 清理旧的 containerd / docker 冲突
sudo apt remove -y docker docker-engine docker.io containerd containerd.io runc || true
sudo apt autoremove -y

# 3. 安装必要软件
sudo apt install -y curl openssl

# 4. 安装官方 Docker & Docker Compose
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 验证 Docker 安装
docker --version
docker compose version

# 5. 启动并设置 Docker 开机启动
sudo systemctl enable docker
sudo systemctl start docker

# 6. 创建部署目录
DEPLOY_DIR="/opt/dendrite-deploy"
sudo mkdir -p "$DEPLOY_DIR"
sudo chown "$USER":"$USER" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# 7. 随机生成 PostgreSQL 密码
POSTGRES_PASSWORD=$(openssl rand -base64 12)
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# 8. 创建 docker-compose.yml
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
      - ./dendrite.yaml:/dendrite.yaml
      - ./matrix_key.pem:/matrix_key.pem
      - ./media_store:/media_store
EOF

# 9. 创建简化 dendrite.yaml
cat > dendrite.yaml <<EOF
server_name: "127.0.0.1"
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

# 10. 创建媒体存储目录和密钥占位
mkdir -p media_store
touch matrix_key.pem

# 11. 启动容器
docker compose up -d

# 12. 显示启动日志
echo "Dendrite 容器启动中，实时日志如下："
docker logs -f dendrite
