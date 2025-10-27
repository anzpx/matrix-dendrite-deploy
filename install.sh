#!/bin/bash
set -e
set -o pipefail

echo "======================================"
echo " Matrix Dendrite 一键部署脚本 (升级版)002"
echo " 适配 Ubuntu 22.04 + Docker"
echo "======================================"

# ===============================
# 1. 基础变量与输入
# ===============================
read -p "安装目录（默认 /opt/dendrite-deploy）： " BASE_DIR
BASE_DIR=${BASE_DIR:-/opt/dendrite-deploy}

read -p "Dendrite 镜像（默认 matrixdotorg/dendrite-monolith:latest）： " DENDRITE_IMG
DENDRITE_IMG=${DENDRITE_IMG:-matrixdotorg/dendrite-monolith:latest}

read -p "Postgres 镜像（默认 postgres:15）： " POSTGRES_IMG
POSTGRES_IMG=${POSTGRES_IMG:-postgres:15}

read -p "服务器域名/IP（默认 38.47.238.148）： " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-38.47.238.148}

read -p "管理员用户名（默认 admin）： " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "若要自定义管理员密码请输入（留空则随机生成）： " ADMIN_PASS
if [ -z "$ADMIN_PASS" ]; then
  ADMIN_PASS=$(openssl rand -base64 12)
fi

read -p "若要自定义 Postgres 密码请输（留空则随机生成）： " DB_PASS
if [ -z "$DB_PASS" ]; then
  DB_PASS=$(openssl rand -base64 12)
fi

echo
echo "[INFO] 使用配置："
echo "  BASE_DIR = $BASE_DIR"
echo "  SERVER_NAME = $SERVER_NAME"
echo "  ADMIN_USER = $ADMIN_USER"
echo "  ADMIN_PASS = $ADMIN_PASS"
echo "  DB_PASS = $DB_PASS"
echo

# ===============================
# 2. 修复 apt 锁定问题
# ===============================
LOCK_FILE="/var/lib/dpkg/lock-frontend"
if fuser "$LOCK_FILE" >/dev/null 2>&1; then
  echo "[WARN] apt 被锁定，检测到 unattended-upgrade 正在运行，正在强制结束..."
  pgrep unattended-upgrade | xargs -r kill -9 || true
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
  dpkg --configure -a
  echo "[INFO] 已清理 apt 锁并修复状态。"
fi

# ===============================
# 3. 安装官方 Docker
# ===============================
echo "[INFO] 检测并安装 Docker 官方版本..."
if command -v docker >/dev/null 2>&1; then
  echo "[INFO] 已检测到 Docker，卸载旧版本及冲突..."
  sudo apt remove -y docker docker-engine docker.io containerd runc docker-compose-plugin || true
  sudo apt autoremove -y
fi

echo "[INFO] 安装依赖包..."
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release software-properties-common

echo "[INFO] 添加 Docker 官方仓库..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# 验证 Docker
docker --version
docker compose version

# ===============================
# 4. 安装其他依赖
# ===============================
echo "[INFO] 安装其他依赖..."
sudo apt install -y openssl curl jq certbot python3-certbot-nginx nano

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ===============================
# 5. 自动清理旧容器（保留配置和 media_store）
# ===============================
echo "[INFO] 检测并清理旧容器..."
OLD_CONTAINERS=("dendrite_postgres" "dendrite")
for c in "${OLD_CONTAINERS[@]}"; do
  if docker ps -a --format '{{.Names}}' | grep -q "^$c\$"; then
    echo "[WARN] 停止并删除旧容器 $c ..."
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm "$c" >/dev/null 2>&1 || true
  fi
done

# ===============================
# 6. 生成 docker-compose.yml
# ===============================
cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  postgres:
    image: $POSTGRES_IMG
    container_name: dendrite_postgres
    restart: always
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: $DB_PASS
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    networks:
      - dendrite-net

  dendrite:
    image: $DENDRITE_IMG
    container_name: dendrite
    depends_on:
      - postgres
    restart: always
    volumes:
      - ./config:/etc/dendrite
      - ./media_store:/var/dendrite/media
    environment:
      - DENDRITE_SERVER_NAME=$SERVER_NAME
      - DENDRITE_DB_HOST=postgres
      - DENDRITE_DB_USER=dendrite
      - DENDRITE_DB_PASSWORD=$DB_PASS
      - DENDRITE_DB_NAME=dendrite
    ports:
      - "8008:8008"
      - "8448:8448"
    networks:
      - dendrite-net

networks:
  dendrite-net:
EOF

# ===============================
# 7. 启动 Postgres 并检测状态
# ===============================
echo "[INFO] 启动 Postgres 并检测数据库是否可用..."
docker compose -f "$BASE_DIR/docker-compose.yml" up -d postgres

for i in {1..12}; do
  sleep 5
  if docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
    echo "[INFO] Postgres 已就绪。"
    break
  else
    echo "[WAIT] Postgres 未就绪，等待中 ($((i*5))s)..."
  fi
  if [ "$i" -eq 12 ]; then
    echo "[WARN] Postgres 启动超时，尝试重启..."
    docker compose -f "$BASE_DIR/docker-compose.yml" restart dendrite_postgres
    sleep 10
  fi
done

# 创建数据库
if ! docker exec dendrite_postgres psql -U dendrite -lqt | cut -d \| -f 1 | grep -qw dendrite; then
  echo "[FIX] 数据库 dendrite 不存在，正在创建..."
  docker exec dendrite_postgres psql -U dendrite -c "CREATE DATABASE dendrite;"
fi

# ===============================
# 8. 生成 dendrite.yaml（修复 logging.hooks 问题）
# ===============================
mkdir -p "$BASE_DIR/config"
cat > "$BASE_DIR/config/dendrite.yaml" <<EOF
global:
  server_name: "$SERVER_NAME"
  private_key: "/etc/dendrite/matrix_key.pem"
  database:
    connection_string: "postgres://dendrite:$DB_PASS@postgres/dendrite?sslmode=disable"
  media_api:
    base_path: "/var/dendrite/media"

logging:
  level: info
  hooks: []
EOF

# ===============================
# 9. 启动 Dendrite
# ===============================
echo "[INFO] 启动 Dendrite..."
docker compose -f "$BASE_DIR/docker-compose.yml" up -d dendrite

# 等待 Dendrite 完全启动
for i in {1..12}; do
  sleep 5
  if docker logs dendrite 2>&1 | grep -q "Listening on"; then
    echo "[INFO] Dendrite 已完全启动。"
    break
  fi
done

# ===============================
# 10. 创建管理员账户
# ===============================
echo "[INFO] 创建管理员账户..."
docker exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml -u "$ADMIN_USER" -p "$ADMIN_PASS" --admin --server-name "$SERVER_NAME" || true

# ===============================
# 11. HTTPS 自动处理
# ===============================
if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[INFO] 服务器为 IP，生成自签名证书..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$BASE_DIR/config/server.key" \
    -out "$BASE_DIR/config/server.crt" \
    -subj "/CN=$SERVER_NAME"
else
  echo "[INFO] 配置 HTTPS（Let's Encrypt）..."
  certbot certonly --standalone -d "$SERVER_NAME" --non-interactive --agree-tos -m admin@$SERVER_NAME || echo "[WARN] 自动签发证书失败"
fi

# ===============================
# 12. 完成信息
# ===============================
echo
echo "🎉 Dendrite 已成功部署！"
echo "--------------------------------------"
echo "访问地址: https://$SERVER_NAME"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASS"
echo "配置路径: $BASE_DIR"
echo "--------------------------------------"
echo
