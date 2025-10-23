#!/bin/bash
# ======================================
# Matrix Dendrite 一键部署脚本
# 支持 Ubuntu 22.04，解决 media_store 挂载和私钥问题
# ======================================

set -e

BASE_DIR="/opt/dendrite"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
MEDIA_DIR="$DATA_DIR/media_store"
CERT_DIR="$BASE_DIR/certs"

# -------------------------------
# 工具函数
# -------------------------------
log() { echo -e "[\033[1;32mINFO\033[0m] $*"; }
err() { echo -e "[\033[1;31mERROR\033[0m] $*" >&2; }

# -------------------------------
# 安装依赖
# -------------------------------
install_dependencies() {
    log "安装依赖..."
    apt update
    apt install -y docker.io docker-compose curl nginx openssl certbot python3-certbot-nginx dnsutils
}

# -------------------------------
# 检查或生成私钥
# -------------------------------
generate_private_key() {
    mkdir -p "$CONFIG_DIR"
    KEY_FILE="$CONFIG_DIR/matrix_key.pem"
    if [[ ! -f "$KEY_FILE" ]]; then
        log "PEM 私钥缺失或不可读，重新生成..."
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
        log "PEM 私钥生成完成: $KEY_FILE"
    else
        log "PEM 私钥已存在: $KEY_FILE"
    fi
}

# -------------------------------
# 创建必要目录
# -------------------------------
prepare_directories() {
    log "创建数据目录..."
    mkdir -p "$MEDIA_DIR"
    mkdir -p "$CERT_DIR"
    chmod -R 777 "$BASE_DIR"
}

# -------------------------------
# 生成自签名证书
# -------------------------------
generate_self_signed_cert() {
    if [[ ! -f "$CERT_DIR/selfsigned.crt" ]]; then
        log "生成自签名证书..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/selfsigned.key" \
            -out "$CERT_DIR/selfsigned.crt" \
            -subj "/C=CN/ST=Beijing/L=Beijing/O=Matrix/CN=localhost"
    fi
}

# -------------------------------
# 生成 Dendrite 配置文件
# -------------------------------
generate_dendrite_config() {
    CONFIG_FILE="$CONFIG_DIR/dendrite.yaml"
    cat > "$CONFIG_FILE" <<EOF
global:
  server_name: "${DOMAIN:-localhost}"
  private_key_file: "$CONFIG_DIR/matrix_key.pem"

database:
  connection_string: "postgres://$DB_USER:$DB_PASSWORD@postgres:5432/dendrite?sslmode=disable"

media_api:
  base_path: /media_store
EOF
    log "Dendrite 配置生成完成: $CONFIG_FILE"
}

# -------------------------------
# 生成 Docker Compose 文件
# -------------------------------
generate_docker_compose() {
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
  postgres:
    image: postgres:15
    container_name: dendrite_postgres
    environment:
      POSTGRES_DB: dendrite
      POSTGRES_USER: $DB_USER
      POSTGRES_PASSWORD: $DB_PASSWORD
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $DB_USER"]
      interval: 5s
      retries: 5

  dendrite:
    image: matrixdotorg/dendrite:latest
    container_name: dendrite_dendrite
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./config:/etc/dendrite
      - ./data/media_store:/media_store
    ports:
      - "8008:8008"
      - "8448:8448"
    restart: unless-stopped

  nginx:
    image: nginx:latest
    container_name: dendrite_nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./certs:/etc/nginx/certs
      - ./config:/etc/dendrite
      - ./nginx.conf:/etc/nginx/nginx.conf
    depends_on:
      - dendrite
EOF
    log "Docker Compose 文件生成完成: $COMPOSE_FILE"
}

# -------------------------------
# 生成 Nginx 配置
# -------------------------------
generate_nginx_config() {
    NGINX_FILE="$BASE_DIR/nginx.conf"
    cat > "$NGINX_FILE" <<EOF
events {}
http {
    server {
        listen 80;
        server_name ${DOMAIN:-localhost};
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 443 ssl;
        server_name ${DOMAIN:-localhost};

        ssl_certificate /etc/nginx/certs/selfsigned.crt;
        ssl_certificate_key /etc/nginx/certs/selfsigned.key;

        location / {
            proxy_pass http://dendrite:8008;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF
    log "Nginx 配置生成完成: $NGINX_FILE"
}

# -------------------------------
# 启动 Docker 容器
# -------------------------------
start_containers() {
    log "启动容器..."
    docker-compose -f "$BASE_DIR/docker-compose.yml" down || true
    docker-compose -f "$BASE_DIR/docker-compose.yml" up -d
}

# -------------------------------
# 主程序
# -------------------------------
echo "======================================"
echo "    Matrix Dendrite 部署脚本"
echo "======================================"
echo "1. 安装 Dendrite"
echo "2. 重新安装 Dendrite"
echo "0. 退出"
echo "======================================"

read -p "请选择操作 [0-2]: " choice

case "$choice" in
    1|2)
        read -p "请输入域名或 VPS IP (回车使用 localhost): " DOMAIN
        read -p "请输入 PostgreSQL 用户名 (回车使用 dendrite): " DB_USER
        DB_USER=${DB_USER:-dendrite}
        read -p "请输入 PostgreSQL 密码 (回车随机生成): " DB_PASSWORD
        DB_PASSWORD=${DB_PASSWORD:-$(openssl rand -base64 12)}
        install_dependencies
        prepare_directories
        generate_private_key
        generate_self_signed_cert
        generate_dendrite_config
        generate_docker_compose
        generate_nginx_config
        start_containers
        log "部署完成！"
        echo "HTTP/HTTPS 地址: ${DOMAIN:-localhost}"
        echo "管理员数据库密码: $DB_PASSWORD"
        ;;
    0)
        log "退出"
        exit 0
        ;;
    *)
        err "无效选项"
        exit 1
        ;;
esac
