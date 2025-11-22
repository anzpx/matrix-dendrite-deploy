#!/bin/bash
# Dendrite 一键部署脚本 v003（增强版）
# 适配 Ubuntu 22.04 + Docker
# 说明：以 root 或者有 sudo 的用户运行
set -euo pipefail
IFS=$'\n\t'

# ------------------------------
# 交互式参数
# ------------------------------
read -p "安装目录（默认 /opt/dendrite-deploy）： " BASE_DIR
BASE_DIR=${BASE_DIR:-/opt/dendrite-deploy}

read -p "Dendrite 镜像（默认 matrixdotorg/dendrite-monolith:latest）： " DENDRITE_IMG
DENDRITE_IMG=${DENDRITE_IMG:-matrixdotorg/dendrite-monolith:latest}

read -p "Postgres 镜像（默认 postgres:15）： " POSTGRES_IMG
POSTGRES_IMG=${POSTGRES_IMG:-postgres:15}

read -p "服务器域名或 IP（默认 38.47.238.148）： " SERVER_NAME
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
echo "  DENDRITE_IMG = $DENDRITE_IMG"
echo "  POSTGRES_IMG = $POSTGRES_IMG"
echo "  SERVER_NAME = $SERVER_NAME"
echo "  ADMIN_USER = $ADMIN_USER"
echo "  ADMIN_PASS = $ADMIN_PASS"
echo "  DB_PASS = $DB_PASS"
echo

# ------------------------------
# 基础检查：必须工具
# ------------------------------
command -v sudo >/dev/null 2>&1 || { echo "[ERROR] 需要 sudo，请安装或使用 root 用户运行"; exit 1; }

# 创建安装目录
sudo mkdir -p "$BASE_DIR"
sudo chown "$(id -u):$(id -g)" "$BASE_DIR"
cd "$BASE_DIR"

# ------------------------------
# 修复 apt 锁（如果存在）
# ------------------------------
LOCK_FILE="/var/lib/dpkg/lock-frontend"
if fuser "$LOCK_FILE" >/dev/null 2>&1; then
  echo "[WARN] 检测到 apt 被占用，尝试终止 unattended-upgrade 并清理锁..."
  sudo pgrep unattended-upgrade | xargs -r sudo kill -9 || true
  sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
  sudo dpkg --configure -a || true
  echo "[INFO] 已清理 apt 锁。"
fi

# ------------------------------
# 安装 Docker 官方版本（如未安装）
# ------------------------------
if ! command -v docker >/dev/null 2>&1 || ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "[INFO] 安装 Docker 官方版..."
  sudo apt update
  sudo apt install -y ca-certificates curl gnupg lsb-release software-properties-common

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo systemctl enable --now docker
else
  echo "[INFO] 检测到 Docker 已安装，跳过安装。"
fi

# 输出 docker 版本
docker --version || true
docker compose version || true

# ------------------------------
# 安装其他常用工具
# ------------------------------
sudo apt update
sudo apt install -y openssl curl jq certbot python3-certbot-nginx nano

# ------------------------------
# 清理旧容器（保留数据卷与 config）
# 如果容器存在，进入升级流程：拉取镜像并重启容器
# ------------------------------
EXIST_POSTGRES=$(docker ps -a --format '{{.Names}}' | grep -x "dendrite_postgres" || true)
EXIST_DENDRITE=$(docker ps -a --format '{{.Names}}' | grep -x "dendrite" || true)

if [ -n "$EXIST_POSTGRES" ] || [ -n "$EXIST_DENDRITE" ]; then
  echo "[WARN] 检测到已存在 dendrite / dendrite_postgres 容器。将执行安全升级（保留数据卷）。"
  echo "[WARN] 如果你希望执行全新部署（删除数据卷），请先手动备份并删除旧容器/卷。"
  echo "[INFO] 拉取最新镜像..."
  docker pull "$POSTGRES_IMG" || true
  docker pull "$DENDRITE_IMG" || true
fi

# ------------------------------
# 生成 docker-compose.yml（使用你输入的镜像/密码）
# ------------------------------
cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.8"

services:
  dendrite_postgres:
    container_name: dendrite_postgres
    image: ${POSTGRES_IMG}
    restart: always
    environment:
      POSTGRES_PASSWORD: "${DB_PASS}"
      POSTGRES_USER: dendrite
      POSTGRES_DB: dendrite
    volumes:
      - dendrite_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - internal

  dendrite:
    container_name: dendrite
    image: ${DENDRITE_IMG}
    restart: unless-stopped
    depends_on:
      dendrite_postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
      - dendrite_media:/var/dendrite/media
      - dendrite_jetstream:/var/dendrite/jetstream
      - dendrite_search_index:/var/dendrite/searchindex
    networks:
      - internal

networks:
  internal:

volumes:
  dendrite_postgres_data:
  dendrite_media:
  dendrite_jetstream:
  dendrite_search_index:
EOF

echo "[INFO] docker-compose.yml 已生成到 $BASE_DIR/docker-compose.yml"

# ------------------------------
# 生成 dendrite 配置目录与私钥（如果不存在）
# ------------------------------
mkdir -p "$BASE_DIR/config"
if [ ! -f "$BASE_DIR/config/matrix_key.pem" ]; then
  echo "[INFO] 生成 dendrite 私钥 matrix_key.pem ..."
  openssl genpkey -algorithm RSA -out "$BASE_DIR/config/matrix_key.pem" -pkeyopt rsa_keygen_bits:2048
  chmod 600 "$BASE_DIR/config/matrix_key.pem"
else
  echo "[INFO] 使用现有私钥 $BASE_DIR/config/matrix_key.pem"
fi

# 生成初始 dendrite.yaml（如果不存在则写入；如果存在不覆盖）
if [ ! -f "$BASE_DIR/config/dendrite.yaml" ]; then
  cat > "$BASE_DIR/config/dendrite.yaml" <<EOF
global:
  server_name: "$SERVER_NAME"
  private_key: "/etc/dendrite/matrix_key.pem"
  database:
    connection_string: "postgres://dendrite:${DB_PASS}@dendrite_postgres/dendrite?sslmode=disable"
  media_api:
    base_path: "/var/dendrite/media"

logging:
  level: info
  hooks: []
EOF
  echo "[INFO] 已生成初始配置 $BASE_DIR/config/dendrite.yaml"
else
  echo "[INFO] dendrite.yaml 已存在，保留原文件（如需覆盖请手动备份后删除再运行）。"
fi

# ------------------------------
# 启动（或更新）服务
# ------------------------------
echo "[INFO] 启动 Postgres..."
docker compose -f "$BASE_DIR/docker-compose.yml" up -d dendrite_postgres

# 等待 Postgres 健康
echo "[INFO] 等待 Postgres 健康就绪（最多 120 秒）..."
for i in {1..24}; do
  if docker ps --format '{{.Names}}' | grep -x dendrite_postgres >/dev/null 2>&1 && docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
    echo "[INFO] Postgres 就绪。"
    break
  fi
  sleep 5
  echo -n "."
  if [ "$i" -eq 24 ]; then
    echo
    echo "[ERROR] Postgres 超时未就绪，请检查容器日志： docker logs dendrite_postgres"
    exit 1
  fi
done

# 创建数据库（如不存在）
echo "[INFO] 确保数据库 dendrite 存在..."
if ! docker exec dendrite_postgres psql -U dendrite -lqt | cut -d \| -f 1 | grep -qw dendrite; then
  docker exec dendrite_postgres psql -U dendrite -c "CREATE DATABASE dendrite;" || { echo "[ERROR] 创建数据库失败"; exit 1; }
  echo "[INFO] 已创建数据库 dendrite."
fi

# 启动 Dendrite 服务
echo "[INFO] 启动 Dendrite 容器..."
docker compose -f "$BASE_DIR/docker-compose.yml" up -d dendrite

# 等待 Dendrite 完全启动（监听端口）
echo "[INFO] 等待 Dendrite 服务启动（最多 120 秒）..."
for i in {1..24}; do
  if docker logs dendrite 2>&1 | grep -i -E "listening on|started" >/dev/null 2>&1; then
    echo "[INFO] Dendrite 已启动。"
    break
  fi
  sleep 5
  echo -n "."
  if [ "$i" -eq 24 ]; then
    echo
    echo "[WARN] Dendrite 启动检测超时，请用 docker logs dendrite 查看详情。"
  fi
done

# ------------------------------
# 创建管理员账户（如尚未创建）
# ------------------------------
echo "[INFO] 尝试创建管理员账户（若已存在会忽略错误）..."
# 使用容器内 create-account（不同镜像路径可能不同，容错处理）
set +e
docker exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml -u "$ADMIN_USER" -p "$ADMIN_PASS" --admin --server-name "$SERVER_NAME" 2>/dev/null
RET=$?
set -e
if [ "$RET" -eq 0 ]; then
  echo "[INFO] 管理员账户创建成功：$ADMIN_USER"
else
  echo "[WARN] 创建管理员账户可能失败或已存在（忽略）：ret=$RET。你可在容器内手动创建或查看日志。"
fi

# ------------------------------
# HTTPS 证书处理（自动判断：IP => 自签名；域名 => Let's Encrypt）
# ------------------------------
is_ip_regex='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
if [[ "$SERVER_NAME" =~ $is_ip_regex ]]; then
  echo "[INFO] 目标是 IP，生成自签名证书到 $BASE_DIR/config/server.*"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$BASE_DIR/config/server.key" \
    -out "$BASE_DIR/config/server.crt" \
    -subj "/CN=$SERVER_NAME"
  echo "[INFO] 自签名证书已生成。"
else
  echo "[INFO] 目标是域名，尝试使用 certbot 获取 Let's Encrypt 证书（standalone 模式）。"
  if ! command -v certbot >/dev/null 2>&1; then
    sudo apt install -y certbot python3-certbot-nginx || true
  fi
  # 尝试自动签发（非交互式）
  if sudo certbot certonly --standalone -d "$SERVER_NAME" --non-interactive --agree-tos -m "admin@$SERVER_NAME"; then
    echo "[INFO] Let's Encrypt 申请成功。证书路径通常在 /etc/letsencrypt/live/$SERVER_NAME/"
    echo "[INFO] 已将证书软链接到 $BASE_DIR/config/（仅便于容器读取）"
    sudo ln -sf "/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem" "$BASE_DIR/config/server.crt"
    sudo ln -sf "/etc/letsencrypt/live/$SERVER_NAME/privkey.pem" "$BASE_DIR/config/server.key"
  else
    echo "[WARN] Let's Encrypt 申请失败，已回退为自签名证书。"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$BASE_DIR/config/server.key" \
      -out "$BASE_DIR/config/server.crt" \
      -subj "/CN=$SERVER_NAME"
  fi
fi

# ------------------------------
# 最终信息与提示
# ------------------------------
echo
echo "======================================"
echo " Dendrite v003 部署完成（或已尝试升级）"
echo " 访问地址: https://$SERVER_NAME (端口 8448)"
echo " 管理员账号: $ADMIN_USER"
echo " 管理员密码: $ADMIN_PASS"
echo " 配置目录: $BASE_DIR/config"
echo " 日志查看： docker logs -f dendrite"
echo " 若需要停止/删除容器（仅容器，不删除卷）:"
echo "   docker compose -f $BASE_DIR/docker-compose.yml down"
echo " 若要完全删除包括卷，请先备份再手动删除卷"
echo "======================================"
echo

# 输出运行状态摘要
docker ps --filter "name=dendrite" --filter "name=dendrite_postgres" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

exit 0
