#!/bin/bash
set -e

# 自动获取 VPS 公网 IP
IP=$(curl -s https://ipinfo.io/ip)
echo "检测到 VPS 公网 IP: $IP"

# 安装依赖
apt update && apt install -y curl openssl docker.io docker-compose

# 启动 Docker
systemctl enable docker --now

# 创建部署目录
DEPLOY_DIR=/opt/dendrite-deploy
mkdir -p $DEPLOY_DIR
cd $DEPLOY_DIR

# 生成 PostgreSQL 密码
POSTGRES_PASSWORD=$(openssl rand -base64 16)
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# 创建最小 dendrite.yaml
cat > dendrite.yaml <<EOF
server_name: "$IP"
pid_file: "/var/run/dendrite.pid"
database:
  type: "postgres"
  connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
EOF

# 生成 Docker Compose 文件
cat > docker-compose.yml <<EOF
version: "3.9"

services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    container_name: dendrite
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./dendrite.yaml:/etc/dendrite/dendrite.yaml

volumes:
  postgres_data:
EOF

# 启动容器
docker compose up -d

echo "部署完成！访问客户端 API: http://$IP:8008"
echo "PostgreSQL 密码: $POSTGRES_PASSWORD"
