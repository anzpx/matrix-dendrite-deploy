#!/bin/bash
# ==============================
# 安全版 Dendrite 一键部署脚本
# ==============================
set -e

DEPLOY_DIR="/opt/dendrite-deploy"
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
    echo "安装 Docker..."
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
        echo "安装 $cmd ..."
        apt update && apt install -y $cmd
    fi
done

# ------------------------------
# Step 2: 创建部署目录
# ------------------------------
echo "===== Step 2: 创建部署目录 ====="
mkdir -p $DEPLOY_DIR
cd $DEPLOY_DIR

# ------------------------------
# Step 3: 生成 docker-compose.yml
# ------------------------------
echo "===== Step 3: 创建 docker-compose.yml ====="
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

volumes:
  postgres_data:
EOF

# ------------------------------
# Step 4: 生成最小 dendrite.yaml
# ------------------------------
echo "===== Step 4: 创建 dendrite.yaml ====="
cat > dendrite.yaml <<EOF
server_name: "$IP"
database:
  accounts:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/postgres?sslmode=disable"
EOF

# ------------------------------
# Step 5: 拉取镜像
# ------------------------------
echo "===== Step 5: 拉取 Docker 镜像 ====="
docker pull postgres:15 || { echo "Postgres 镜像拉取失败，请检查网络"; exit 1; }
docker pull matrixdotorg/dendrite-monolith:latest || { echo "Dendrite 镜像拉取失败，请检查网络"; exit 1; }

# ------------------------------
# Step 6: 启动容器
# ------------------------------
echo "===== Step 6: 启动容器 ====="
docker compose up -d

# ------------------------------
# Step 7: 状态检查
# ------------------------------
echo "===== Step 7: 状态检查 ====="
sleep 5
docker ps -a

echo "部署完成！访问客户端 API: http://$IP:8008"
