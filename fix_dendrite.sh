#!/bin/bash
# ================================================
# 一键修复 Dendrite 配置并重启容器
# 适用环境: Ubuntu 22.04 + Docker Compose
# ================================================

DEPLOY_DIR="/opt/dendrite-deploy"
CONFIG_FILE="$DEPLOY_DIR/dendrite.yaml"
POSTGRES_PASSWORD="yourpassword"  # 修改为你的 PostgreSQL 密码
SERVER_NAME="38.47.238.148"       # 修改为你的 VPS IP 或域名

echo "[1/4] 备份旧配置文件..."
cp "$CONFIG_FILE" "$CONFIG_FILE.bak_$(date +%s)"

echo "[2/4] 写入新的 dendrite.yaml 配置..."
cat > "$CONFIG_FILE" <<EOF
server_name: "$SERVER_NAME"
pid_file: "/var/run/dendrite.pid"
report_stats: false
private_key_path: "./matrix_key.pem"

logging:
  level: info
  hooks:
    - type: file
      level: info
      path: "./dendrite.log"

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

echo "[3/4] 重启 Dendrite 容器..."
cd "$DEPLOY_DIR"
docker compose restart dendrite

echo "[4/4] 查看 Dendrite 容器状态..."
docker compose ps
docker logs -f dendrite
