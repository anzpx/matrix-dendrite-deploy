#!/bin/bash
set -e

echo "======================================"
echo " Matrix Dendrite 一键部署脚本 (升级版)"
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
# 2. 自动修复 apt 锁定问题
# ===============================
echo "[INFO] 检查 apt 是否被锁定..."
LOCK_FILE="/var/lib/dpkg/lock-frontend"
if fuser "$LOCK_FILE" >/dev/null 2>&1; then
  echo "[WARN] apt 被锁定，检测到 unattended-upgrade 正在运行，正在强制结束..."
  pgrep unattended-upgrade | xargs -r kill -9 || true
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
  dpkg --configure -a
  echo "[INFO] 已清理 apt 锁并修复状态。"
fi

# ===============================
# 3. 安装依赖
# ===============================
echo "[INFO] 更新 apt 并安装依赖..."
apt update -y
apt install -y docker.io docker-compose openssl curl jq

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ===============================
# 4. 生成 docker-compose.yml
# ===============================
cat > docker-compose.yml <<EOF
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
# 5. 启动 Postgres 并检测状态
# ===============================
echo "[INFO] 启动 Postgres 并检测数据库是否可用..."
docker compose up -d postgres

for i in {1..12}; do
  sleep 5
  if docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
    echo "[INFO] Postgres 已就绪。"
    break
  else
    echo "[WAIT] Postgres 未就绪，等待中 ($((i*5))s)..."
  fi
  if [ "$i" -eq 12 ]; then
    echo "[ERR] Postgres 启动超时，尝试修复..."
    docker compose restart postgres
    sleep 10
  fi
done

# 检查并创建数据库
if ! docker exec dendrite_postgres psql -U dendrite -lqt | cut -d \| -f 1 | grep -qw dendrite; then
  echo "[FIX] 数据库 dendrite 不存在，正在创建..."
  docker exec dendrite_postgres psql -U dendrite -c "CREATE DATABASE dendrite;"
fi

# ===============================
# 6. 生成 dendrite.yaml 配置文件
# ===============================
mkdir -p "$BASE_DIR/config"
cat > "$BASE_DIR/config/dendrite.yaml" <<EOF
version: 2
global:
  server_name: "$SERVER_NAME"
  private_key: "/etc/dendrite/matrix_key.pem"
  database:
    connection_string: "postgres://dendrite:$DB_PASS@postgres/dendrite?sslmode=disable"
  media_api:
    base_path: "/var/dendrite/media"
EOF

# ===============================
# 7. 启动 Dendrite
# ===============================
echo "[INFO] 启动 Dendrite..."
docker compose up -d dendrite
sleep 10

if ! docker ps | grep -q dendrite; then
  echo "[ERR] Dendrite 启动失败，日志如下："
  docker logs dendrite
  exit 1
fi

# ===============================
# 8. 自动创建管理员账户
# ===============================
echo "[INFO] 创建管理员账户..."
docker exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml -u "$ADMIN_USER" -p "$ADMIN_PASS" --admin --server-name "$SERVER_NAME" || true

# ===============================
# 9. HTTPS 自动申请证书
# ===============================
echo "[INFO] 配置 HTTPS（Let's Encrypt）..."
apt install -y certbot python3-certbot-nginx
certbot certonly --standalone -d "$SERVER_NAME" --non-interactive --agree-tos -m admin@$SERVER_NAME || echo "[WARN] 自动签发证书失败，请稍后手动执行 certbot。"

# ===============================
# 10. 完成信息
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
