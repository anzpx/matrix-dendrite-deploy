#!/bin/bash
# =====================================================
# 升级版一键部署 Matrix Dendrite 脚本 (Ubuntu 22.04+)
# 自动安装 Docker/Docker Compose，生成配置文件
# 自动清理残留容器/镜像/卷，防止启动错误
# =====================================================

set -e

echo "===== Step 1: 更新系统 & 安装依赖 ====="
sudo apt update
sudo apt install -y curl openssl apt-transport-https ca-certificates software-properties-common gnupg lsb-release

echo "===== Step 2: 安装 Docker ====="
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable docker
sudo systemctl start docker

echo "===== Step 3: 清理残留 Docker 内容 ====="
docker compose down || true
docker rm -f dendrite dendrite_postgres 2>/dev/null || true
docker rmi -f matrixdotorg/dendrite-monolith:latest postgres:15 2>/dev/null || true
docker volume rm dendrite-postgres_data 2>/dev/null || true
docker network prune -f || true
docker system prune -af || true

echo "===== Step 4: 创建部署目录 ====="
DEPLOY_DIR="/opt/dendrite-deploy"
sudo mkdir -p $DEPLOY_DIR
sudo chown $USER:$USER $DEPLOY_DIR
cd $DEPLOY_DIR

echo "===== Step 5: 获取 VPS 公网 IP ====="
VPS_IP=$(curl -s https://api.ipify.org)
echo "VPS 公网 IP: $VPS_IP"

echo "===== Step 6: 生成 PostgreSQL 密码 ====="
POSTGRES_PASSWORD=$(openssl rand -base64 16)
echo "PostgreSQL 密码: $POSTGRES_PASSWORD"

echo "===== Step 7: 创建 docker-compose.yml ====="
cat > docker-compose.yml <<EOF
version: "3.9"
services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_USER: dendrite
      POSTGRES_DB: dendrite
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite"]
      interval: 10s
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
      - ./matrix_key.pem:/etc/dendrite/matrix_key.pem

volumes:
  postgres_data:
EOF

echo "===== Step 8: 创建最小 dendrite.yaml ====="
cat > dendrite.yaml <<EOF
global:
  server_name: "${VPS_IP}"
  private_key_path: "./matrix_key.pem"
  report_stats: false

database:
  type: "postgres"
  args:
    user: "dendrite"
    password: "${POSTGRES_PASSWORD}"
    database: "dendrite"
    host: "postgres"
    port: 5432

logging:
  level: "info"

http:
  client_api:
    listen: ":8008"
  federation_api:
    listen: ":8448"
EOF

echo "===== Step 9: 生成密钥文件 ====="
openssl genrsa -out matrix_key.pem 2048

echo "===== Step 10: 拉取镜像 ====="
docker pull postgres:15
docker pull matrixdotorg/dendrite-monolith:latest

echo "===== Step 11: 启动 Dendrite 容器 ====="
docker compose up -d

echo "===== Step 12: 状态检查 ====="
docker ps -a
echo "部署完成！访问客户端 API: http://${VPS_IP}:8008"
