#!/bin/bash
# ==============================
# 安全版 Dendrite 一键部署脚本（升级版）
# ==============================
set -e

DEPLOY_DIR="/opt/dendrite-deploy"
KEY_DIR="$DEPLOY_DIR/keys"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 16)}"

# 获取公网 IP
IP=$(curl -s https://api.ipify.org)
echo "检测到 VPS 公网 IP: $IP"
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# ------------------------------
# Step 1: 安装必要软件
# ------------------------------
echo "===== Step 1: 安装 Docker、docker-compose、curl、openssl ====="
if ! command -v docker >/dev/null; then
    apt update && apt install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

for cmd in curl openssl; do
    if ! command -v $cmd >/dev/null; then
        apt update && apt install -y $cmd
    fi
done

# ------------------------------
# Step 2: 创建部署目录和私钥目录
# ------------------------------
echo "===== Step 2: 创建部署目录 ====="
mkdir -p $DEPLOY_DIR $KEY_DIR
cd $DEPLOY_DIR

# ------------------------------
# Step 3: 生成私钥
# ------------------------------
echo "===== Step 3: 生成 Dendrite 私钥 ====="
if [ ! -f "$KEY_DIR/matrix_key.pem" ]; then
    openssl genpkey -algorithm ED25519 -out "$KEY_DIR/matrix_key.pem"
    chmod 400 "$KEY_DIR/matrix_key.pem"
fi

# ------------------------------
# Step 4: 生成 docker-compose.yml
# ------------------------------
echo "===== Step 4: 创建 docker-compose.yml ====="
cat > docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    environment:
      POSTGRES_PASSWORD: "$POSTGRES_PASSWORD"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      retries: 5

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
      - ./keys/matrix_key.pem:/etc/dendrite/matrix_key.pem:ro

volumes:
  postgres_data:
EOF

# ------------------------------
# Step 5: 生成最小 dendrite.yaml
# ------------------------------
echo "===== Step 5: 创建 dendrite.yaml ====="
cat > dendrite.yaml <<EOF
server_name: "$IP"
key:
  private_key: "/etc/dendrite/matrix_key.pem"
database:
  accounts:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/postgres?sslmode=disable"
EOF

# ------------------------------
# Step 6: 拉取 Docker 镜像
# ------------------------------
echo "===== Step 6: 拉取 Docker 镜像 ====="
docker pull postgres:15 || { echo "Postgres 镜像拉取失败"; exit 1; }
docker pull matrixdotorg/dendrite-monolith:latest || { echo "Dendrite 镜像拉取失败"; exit 1; }

# ------------------------------
# Step 7: 启动容器
# ------------------------------
echo "===== Step 7: 启动容器 ====="
docker compose up -d --remove-orphans

# ------------------------------
# Step 8: 等待 Postgres 健康
# ------------------------------
echo "===== Step 8: 等待 Postgres 健康 ====="
for i in {1..30}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' dendrite_postgres)
    if [ "$STATUS" == "healthy" ]; then
        echo "Postgres 已健康"
        break
    fi
    echo "等待 Postgres 健康中... ($i/30)"
    sleep 2
done

# ------------------------------
# Step 9: 启动 Dendrite
# ------------------------------
docker restart dendrite

# ------------------------------
# Step 10: 状态检查
# ------------------------------
echo "===== Step 10: 状态检查 ====="
sleep 5
docker ps -a

echo "1部署完成！访问客户端 API: http://$IP:8008"
