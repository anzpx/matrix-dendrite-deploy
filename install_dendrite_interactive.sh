#!/bin/bash
# ================================
# 一键安装 Docker + Dendrite
# ================================

set -e

echo "==> 更新系统并安装依赖..."
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release sudo

echo "==> 添加 Docker 官方 GPG 密钥和源..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> 安装 Docker 及 Docker Compose 插件..."
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> 启动 Docker 服务..."
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl status docker --no-pager

echo "==> 创建 Dendrite 目录结构..."
sudo mkdir -p /opt/dendrite/config /opt/dendrite/data/db /opt/dendrite/data/media_store
sudo chown -R $USER:$USER /opt/dendrite

echo "==> 生成 Dendrite 私钥..."
openssl genpkey -algorithm ED25519 -out /opt/dendrite/config/matrix_key.pem
openssl pkey -in /opt/dendrite/config/matrix_key.pem -pubout -out /opt/dendrite/config/matrix_key.pem.pub

echo "==> 生成自签名证书..."
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
 -keyout /opt/dendrite/config/selfsigned.key \
 -out /opt/dendrite/config/selfsigned.crt \
 -subj "/CN=localhost"

echo "==> 生成 dendrite.yaml..."
cat > /opt/dendrite/config/dendrite.yaml <<'EOF'
version: 2
global:
  server_name: "localhost"
  private_key: "/etc/dendrite/matrix_key.pem"
  database:
    connection_string: "postgres://dendrite:password@db/dendrite?sslmode=disable"
  media_api:
    base_path: "/var/dendrite/media_store"
EOF

echo "==> 生成 docker-compose.yml..."
cat > /opt/dendrite/docker-compose.yml <<'EOF'
version: "3.8"
services:
  db:
    image: postgres:14
    container_name: dendrite_db
    restart: always
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: password
      POSTGRES_DB: dendrite
    volumes:
      - ./data/db:/var/lib/postgresql/data
  dendrite:
    image: ghcr.io/matrix-org/dendrite-monolith:latest
    container_name: dendrite
    restart: always
    depends_on:
      - db
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
      - ./data/media_store:/var/dendrite/media_store
EOF

echo "==> 启动 Dendrite..."
cd /opt/dendrite
docker compose up -d

echo "==> 安装完成，检查容器状态..."
docker ps
echo "==> 你可以通过 http://localhost:8008/_matrix/client/versions 检查服务是否启动"
