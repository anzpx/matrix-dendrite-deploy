#!/bin/bash
# ==============================
# 安全版 Dendrite 升级一键部署脚本
# ==============================
set -e

DEPLOY_DIR="/opt/dendrite-deploy"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 16)}"

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exit 1
fi

# 获取公网 IP
IP=$(curl -s https://api.ipify.org || echo "127.0.0.1")
echo "检测到 VPS 公网 IP: $IP"
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# ------------------------------
# Step 1: 安装必要软件
# ------------------------------
echo "===== Step 1: 安装 Docker、docker-compose、curl、openssl ====="
if ! command -v docker >/dev/null; then
    echo "安装 Docker..."
    apt update && apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # 启动 Docker 服务
    systemctl enable docker
    systemctl start docker
fi

# 安装必要的工具
for cmd in curl openssl; do
    if ! command -v $cmd >/dev/null; then
        echo "安装 $cmd ..."
        apt update && apt install -y $cmd
    fi
done

# 检查 docker-compose 是否可用
if ! docker compose version >/dev/null 2>&1; then
    echo "安装 docker-compose-plugin..."
    apt update && apt install -y docker-compose-plugin
fi

# ------------------------------
# Step 2: 创建部署目录
# ------------------------------
echo "===== Step 2: 创建部署目录 ====="
mkdir -p $DEPLOY_DIR/media_store
cd $DEPLOY_DIR

# ------------------------------
# Step 3: 清理旧容器和卷
# ------------------------------
echo "===== Step 3: 清理旧容器和卷 ====="
if [ -f "docker-compose.yml" ]; then
    docker compose down --remove-orphans || true
fi
docker system prune -af || true

# ------------------------------
# Step 4: 生成密钥文件
# ------------------------------
if [ ! -f matrix_key.pem ]; then
    echo "===== Step 4: 生成 matrix_key.pem ====="
    openssl genpkey -out matrix_key.pem -outform PEM -algorithm RSA -pkeyopt rsa_keygen_bits:2048
    chmod 600 matrix_key.pem
fi

# ------------------------------
# Step 5: 生成 dendrite.yaml (版本2配置)
# ------------------------------
echo "===== Step 5: 创建 dendrite.yaml (版本2) ====="
cat > dendrite.yaml <<EOF
version: 2
global:
  server_name: "$IP"
  private_key: /etc/dendrite/matrix_key.pem
  well_known_server_name: "$IP:8448"
  presence:
    enable_inbound: true
    enable_outbound: true

client_api:
  registration_shared_secret: "$(openssl rand -hex 32)"
  enable_registration: true
  registration_requires_token: false
  enable_guests: true
  rate_limiting:
    enabled: true
    threshold: 100
    cooloff_ms: 500

federation_api:
  send:
    max_retries: 16
    max_retries_for_server: 8
    disable_tls_validation: false
  key_validity:
    cache_size: 1024
    cache_lifetime: 1h0m0s

app_service_api: {}

key_server:
  prefer_direct_fetch: false

media_api:
  base_path: /var/dendrite/media-store
  max_file_size_bytes: 10485760
  dynamic_thumbnails: true
  max_thumbnail_generators: 10
  allow_remote: true

sync_api:
  realtime_enabled: true
  full_text_search:
    enabled: false
    index_path: /var/dendrite/searchindex

user_api:
  account_database:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  device_database:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"

database:
  account:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  device:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  mediaapi:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  syncapi:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  roomserver:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  keydb:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  federationapi:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  appservice:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  presence:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  pushserver:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"
  relayapi:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/dendrite?sslmode=disable"

logging:
- type: file
  level: info
  params:
    path: /var/log/dendrite
EOF

# ------------------------------
# Step 6: 生成 docker-compose.yml
# ------------------------------
echo "===== Step 6: 创建 docker-compose.yml ====="
cat > docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    environment:
      POSTGRES_PASSWORD: "$POSTGRES_PASSWORD"
      POSTGRES_DB: dendrite
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    container_name: dendrite
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./dendrite.yaml:/etc/dendrite/dendrite.yaml:ro
      - ./matrix_key.pem:/etc/dendrite/matrix_key.pem:ro
      - ./media_store:/var/dendrite/media-store:rw
    restart: unless-stopped
    command: [
      "--config=/etc/dendrite/dendrite.yaml"
    ]

volumes:
  postgres_data:
EOF

# ------------------------------
# Step 7: 拉取镜像
# ------------------------------
echo "===== Step 7: 拉取 Docker 镜像 ====="
docker pull postgres:15
docker pull matrixdotorg/dendrite-monolith:latest

# ------------------------------
# Step 8: 启动容器
# ------------------------------
echo "===== Step 8: 启动容器 ====="
docker compose up -d

# ------------------------------
# Step 9: 检查容器状态，失败输出日志
# ------------------------------
echo "===== Step 9: 状态检查 ====="
echo "等待容器启动..."
sleep 10

# 检查容器状态
docker ps -a

# 检查 dendrite 容器状态
MAX_RETRIES=10
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    DENDRITE_STATUS=$(docker inspect -f '{{.State.Status}}' dendrite 2>/dev/null || echo "not_found")
    if [ "$DENDRITE_STATUS" = "running" ]; then
        echo "✅ dendrite 容器运行正常"
        break
    elif [ "$DENDRITE_STATUS" = "not_found" ]; then
        echo "❌ dendrite 容器不存在"
        docker logs dendrite || echo "无法读取日志"
        exit 1
    else
        echo "⏳ dendrite 容器状态: $DENDRITE_STATUS, 等待中... ($((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT+1))
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "❌ dendrite 容器启动超时，输出日志："
    docker logs dendrite
    exit 1
fi

# 检查服务是否正常响应
echo "检查服务响应..."
if curl -f http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
    echo "✅ Matrix 服务响应正常"
else
    echo "⚠️ Matrix 服务未正常响应，检查日志..."
    docker logs dendrite
fi

echo "=========================================="
echo "✅ 部署完成！"
echo "客户端 API: http://$IP:8008"
echo "联邦 API: https://$IP:8448"
echo "PostgreSQL 密码: $POSTGRES_PASSWORD"
echo "=========================================="
echo "下一步："
echo "1. 配置防火墙开放端口 8008 和 8448"
echo "2. 可以使用 Element 等客户端连接服务器"
echo "3. 查看日志: docker logs -f dendrite"
echo "=========================================="
