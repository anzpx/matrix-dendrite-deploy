#!/bin/bash
# ==============================
# 官方结构升级版 Dendrite 一键部署脚本
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
# Step 2: 创建部署目录和子目录
# ------------------------------
echo "===== Step 2: 创建目录结构 ====="
mkdir -p $DEPLOY_DIR/media_store
cd $DEPLOY_DIR

# ------------------------------
# Step 3: 生成 Docker Compose 文件
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
      - ./matrix_key.pem:/etc/dendrite/matrix_key.pem:ro
      - ./media_store:/var/dendrite/media_store:rw

volumes:
  postgres_data:
EOF

# ------------------------------
# Step 4: 生成 dendrite.yaml 配置
# ------------------------------
echo "===== Step 4: 创建 dendrite.yaml ====="
cat > dendrite.yaml <<EOF
server_name: "$IP"
key:
  private_key: "/etc/dendrite/matrix_key.pem"
database:
  accounts:
    connection_string: "postgres://postgres:$POSTGRES_PASSWORD@postgres:5432/postgres?sslmode=disable"
media_api:
  base_path: "/var/dendrite/media_store"
EOF

# ------------------------------
# Step 5: 生成私钥
# ------------------------------
echo "===== Step 5: 生成私钥 ====="
if [ ! -f matrix_key.pem ]; then
    openssl genrsa -out matrix_key.pem 2048
    chmod 600 matrix_key.pem
fi

# ------------------------------
# Step 6: 拉取镜像
# ------------------------------
echo "===== Step 6: 拉取 Docker 镜像 ====="
docker pull postgres:15
docker pull matrixdotorg/dendrite-monolith:latest

# ------------------------------
# Step 7: 启动容器
# ------------------------------
echo "===== Step 7: 启动容器 ====="
docker compose down --remove-orphans
docker compose up -d

# ------------------------------
# Step 8: 检查 Dendrite 是否运行
# ------------------------------
echo "===== Step 8: 检查 Dendrite 容器 ====="
sleep 5

STATUS=$(docker inspect -f '{{.State.Status}}' dendrite)
if [ "$STATUS" != "running" ]; then
    echo "Dendrite 容器启动失败，显示日志："
    docker logs dendrite --tail 50
    echo "尝试重启容器..."
    docker compose restart dendrite
    sleep 5
    docker logs dendrite --tail 50
fi

docker ps -a
echo "部署完成！访问客户端 API: http://$IP:8008"
