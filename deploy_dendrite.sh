#!/bin/bash
set -e

DEPLOY_DIR="/opt/dendrite-deploy"
mkdir -p "$DEPLOY_DIR/media_store"
cd "$DEPLOY_DIR"

# 自动获取 VPS IP
VPS_IP=$(ip -4 addr show ens3 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "检测到 VPS 公网 IP: $VPS_IP"

# 生成 PostgreSQL 密码
POSTGRES_PASSWORD=$(openssl rand -base64 12)
echo "生成 PostgreSQL 密码: $POSTGRES_PASSWORD"

# 创建空密钥文件
touch matrix_key.pem

# 创建 docker-compose.yml
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
    command: >
      sh -c "cat > /dendrite.yaml <<EOL
server_name: '$VPS_IP'
pid_file: '/var/run/dendrite.pid'
report_stats: false
private_key_path: '/matrix_key.pem'

logging:
  level: info

database:
  connection_string: 'postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite?sslmode=disable'

http_api:
  listen: '0.0.0.0:8008'
  enable_metrics: true

federation_api:
  listen: '0.0.0.0:8448'

media_api:
  base_path: '/media_store'
  listen: '0.0.0.0:8800'

room_server:
  database:
    connection_string: 'postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite_roomserver?sslmode=disable'

account_server:
  database:
    connection_string: 'postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite_accounts?sslmode=disable'

sync_api:
  database:
    connection_string: 'postgres://postgres:$POSTGRES_PASSWORD@dendrite_postgres:5432/dendrite_sync?sslmode=disable'
EOL
      && /usr/bin/dendrite"
    volumes:
      - ./matrix_key.pem:/matrix_key.pem
      - ./media_store:/media_store
volumes:
  postgres_data:
EOF

# 启动容器
docker compose up -d

# 查看日志
docker logs -f dendrite
