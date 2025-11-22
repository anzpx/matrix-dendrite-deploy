#!/bin/bash
set -e

echo "===== Step 0: 获取 VPS 公网 IP ====="
VPS_IP=$(curl -s https://ip.gs || curl -s https://api.ipify.org)
echo "检测到 VPS 公网 IP: $VPS_IP"

echo "===== Step 1: 卸载旧 Docker 并清理残留 ====="
sudo apt remove -y docker docker-engine docker.io containerd runc || true
sudo apt purge -y docker docker-engine docker.io containerd runc || true
sudo apt autoremove -y
sudo rm -rf /var/lib/docker /var/lib/containerd

echo "===== Step 2: 安装 Docker 官方依赖 ====="
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release openssl

echo "===== Step 3: 添加 Docker 官方源 ====="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update

echo "===== Step 4: 安装 Docker + Compose Plugin ====="
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable docker
sudo systemctl start docker

echo "===== Step 5: 创建 Dendrite 部署目录 ====="
DEPLOY_DIR=/opt/dendrite-deploy
sudo mkdir -p $DEPLOY_DIR
cd $DEPLOY_DIR

echo "===== Step 6: 生成 PostgreSQL 密码 ====="
POSTGRES_PASSWORD=$(openssl rand -base64 12)
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

echo "===== Step 7: 创建 docker-compose.yml ====="
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
      - ./dendrite.yaml:/dendrite.yaml
      - ./matrix_key.pem:/matrix_key.pem
      - ./media_store:/media_store

volumes:
  postgres_data:
EOF

echo "===== Step 8: 创建最小可用 dendrite.yaml ====="
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

echo "===== Step 9: 创建空目录和密钥占位 ====="
mkdir -p media_store
touch matrix_key.pem

echo "===== Step 10: 启动 Dendrite 容器 ====="
docker compose up -d

echo "===== Step 11: 查看容器日志 ====="
docker logs -f dendrite
