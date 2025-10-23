#!/bin/bash
set -euo pipefail

# =========================
# Matrix Dendrite 一键部署
# 增强：自动检测并清理残留 Docker 容器 / 网络
# =========================

BASE_DIR="/opt/dendrite"
LOG_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
MEDIA_DIR="$DATA_DIR/media_store"
CERT_DIR="$BASE_DIR/certs"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

trap 'on_exit $?' EXIT

on_exit() {
    local rc=$1
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}脚本执行失败（exit code $rc）。打印最近日志以便排查：${NC}"
        if [ -f "$COMPOSE_FILE" ]; then
            echo -e "${YELLOW}== docker-compose ps ==${NC}"
            (cd "$BASE_DIR" && docker-compose ps) || true
            echo -e "${YELLOW}== dendrite logs (tail 100) ==${NC}"
            (cd "$BASE_DIR" && docker-compose logs dendrite --tail=100) || true
            echo -e "${YELLOW}== postgres logs (tail 100) ==${NC}"
            (cd "$BASE_DIR" && docker-compose logs postgres --tail=100) || true
        else
            echo -e "${YELLOW}docker-compose.yml 不存在，列出含 'dendrite' 名称的容器：${NC}"
            docker ps -a --filter "name=dendrite" || true
        fi
    fi
    exit "$rc"
}

show_menu() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}    Matrix Dendrite 自动部署脚本${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1. 安装 Dendrite${NC}"
    echo -e "${YELLOW}2. 重新安装 Dendrite${NC}"
    echo -e "${RED}0. 退出${NC}"
    echo -e "${BLUE}======================================${NC}"
}

# 清理残留容器/网络（安全：仅删除名字包含 dendrite 的容器与 dendrite_default 网络）
clean_previous_environment() {
    echo -e "${YELLOW}检测并清理残留的 dendrite 容器/网络（如果存在）...${NC}"

    # 如果有 /opt/dendrite/docker-compose.yml，优先使用 docker-compose down -v
    if [ -f "$COMPOSE_FILE" ]; then
        echo "- 发现 $COMPOSE_FILE，执行 docker-compose down -v"
        (cd "$BASE_DIR" && docker-compose down -v) || echo "- docker-compose down 失败，继续后续清理"
    fi

    # 强制删除所有名字中包含 dendrite 的容器（谨慎）
    local cids
    cids=$(docker ps -a --filter "name=dendrite" -q || true)
    if [ -n "$cids" ]; then
        echo "- 删除残留容器: $cids"
        docker rm -f $cids || true
    else
        echo "- 无残留 dendrite 容器"
    fi

    # 删除名为 dendrite_default 的网络（如果存在）
    if docker network ls --format '{{.Name}}' | grep -q '^dendrite_default$'; then
        echo "- 删除网络 dendrite_default"
        docker network rm dendrite_default || true
    else
        echo "- 无 dendrite_default 网络"
    fi

    echo -e "${GREEN}残留环境清理完成${NC}"
}

check_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}错误：系统未安装 docker，请先安装${NC}"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}错误：docker 未正常运行，请启动 docker 服务${NC}"
        exit 1
    fi
}

# 等待并打印失败日志（Postgres）
wait_for_postgres() {
    echo "[*] 等待 PostgreSQL 就绪..."
    local timeout=60 elapsed=0
    while :; do
        if docker-compose exec -T postgres pg_isready -U dendrite -d dendrite >/dev/null 2>&1; then
            echo "PostgreSQL 已就绪"
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e "${RED}PostgreSQL 启动超时 (${timeout}s)。打印日志：${NC}"
            docker-compose logs postgres --tail=200 || true
            return 1
        fi
        echo "PostgreSQL 未就绪，等待 5 秒..."
        sleep 5
        elapsed=$((elapsed+5))
    done
}

# 等待 dendrite 容器就绪（尝试执行一个简短命令）
wait_for_dendrite() {
    echo "[*] 等待 Dendrite 容器就绪..."
    local timeout=90 elapsed=0
    while :; do
        # 如果容器不存在或在重启中，会导致 docker-compose exec 返回错误
        if docker-compose ps | grep -q 'dendrite'; then
            if docker-compose exec -T dendrite /usr/bin/dendrite-monolith --version >/dev/null 2>&1; then
                echo "Dendrite 已就绪"
                return 0
            fi
        else
            echo "Dendrite 容器尚未创建"
        fi

        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e "${RED}Dendrite 启动超时 (${timeout}s)。打印日志并退出：${NC}"
            docker-compose ps || true
            docker-compose logs dendrite --tail=200 || true
            return 1
        fi

        echo "Dendrite 容器未就绪，等待 5 秒..."
        sleep 5
        elapsed=$((elapsed+5))
    done
}

# 主安装流程
install_dendrite() {
    echo -e "${GREEN}[开始安装 Dendrite]${NC}"

    # 先检查 docker
    check_docker_available

    # 创建目录并设置权限
    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$DATA_DIR/postgres" "$MEDIA_DIR" "$CERT_DIR"
    # media 目录必须为容器可写
    chmod 0777 "$MEDIA_DIR" || true
    chmod 0755 "$CONFIG_DIR" || true
    chmod 0755 "$LOG_DIR" || true

    # 启动日志收集（并记录本次运行日志）
    exec > >(tee -a "$LOG_DIR/install.log") 2>&1

    # 读取用户输入
    VPS_IP=$(curl -s ifconfig.me || echo "")
    read -p "请输入域名或 VPS IP (回车自动使用 VPS IP: ${VPS_IP}): " DOMAIN
    DOMAIN=${DOMAIN:-$VPS_IP}

    read -s -p "请输入 PostgreSQL 数据库密码 (回车随机生成): " DB_PASS
    echo
    DB_PASS=${DB_PASS:-$(openssl rand -base64 12)}

    read -p "请输入管理员账号用户名 (回车随机生成): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-user_$(openssl rand -hex 5)}

    read -s -p "请输入管理员账号密码 (回车随机生成): " ADMIN_PASS
    echo
    ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -base64 12)}

    echo
    echo "使用配置如下:"
    echo "  域名/IP: $DOMAIN"
    echo "  数据库密码: $DB_PASS"
    echo "  管理员账号: $ADMIN_USER"
    echo "  管理员密码: $ADMIN_PASS"
    echo "======================================"

    echo "[1/7] 安装系统依赖（docker / docker-compose / nginx / certbot / openssl / dnsutils）"
    apt update -y
    apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl
    systemctl enable --now docker

    # 检查并清理残留环境（会自动删除名字含 'dendrite' 的容器和网络）
    clean_previous_environment

    # 检查域名解析
    DNS_IP=$(dig +short "$DOMAIN" | head -n1 || echo "")
    USE_LETSENCRYPT="no"
    if [[ -n "$DNS_IP" && "$DNS_IP" == "$VPS_IP" && "$DOMAIN" != "$VPS_IP" ]]; then
        echo "✅ 域名解析到 VPS，启用 Let's Encrypt"
        USE_LETSENCRYPT="yes"
    else
        echo "⚠️ 域名未解析到 VPS 公网 IP，将使用 VPS IP 或自签名证书"
        DOMAIN="$VPS_IP"
    fi

    echo "[2/7] 生成私钥（ED25519）并设置容器可读权限"
    openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem"
    chmod 0644 "$CONFIG_DIR/matrix_key.pem" || true

    echo "[3/7] 生成配置文件 dendrite.yaml"
    cat > "$CONFIG_DIR/dendrite.yaml" <<EOF
global:
  server_name: $DOMAIN
  private_key: /etc/dendrite/matrix_key.pem

database:
  connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

client_api:
  internal_api:
    connect: http://localhost:7771
    listen: http://0.0.0.0:7771
  external_api:
    listen: http://0.0.0.0:8008

federation_api:
  internal_api:
    connect: http://localhost:7772
    listen: http://0.0.0.0:7772
  external_api:
    listen: http://0.0.0.0:8448

media_api:
  internal_api:
    connect: http://localhost:7775
    listen: http://0.0.0.0:7775
  external_api:
    listen: http://0.0.0.0:8075
  base_path: /etc/dendrite/media_store

sync_api:
  internal_api:
    connect: http://localhost:7773
    listen: http://0.0.0.0:7773

user_api:
  internal_api:
    connect: http://localhost:7781
    listen: http://0.0.0.0:7781
  account_database:
    connection_string: postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable

logging:
- type: file
  level: info
  params:
    path: /var/log/dendrite.log
EOF

    echo "[4/7] 生成 docker-compose.yml"
    cat > "$COMPOSE_FILE" <<EOF
version: '3.7'
services:
  postgres:
    image: postgres:15
    environment:
      - POSTGRES_USER=dendrite
      - POSTGRES_PASSWORD=$DB_PASS
      - POSTGRES_DB=dendrite
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U dendrite -d dendrite"]
      interval: 5s
      timeout: 5s
      retries: 10

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    depends_on:
      - postgres
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
      - ./data/media_store:/etc/dendrite/media_store
      - ./logs:/var/log
    command: /usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml
    restart: unless-stopped
EOF

    echo "[5/7] 启动服务 (docker-compose up -d)"
    cd "$BASE_DIR"
    docker-compose down -v || true
    docker-compose up -d

    echo "[*] 等待 PostgreSQL 就绪并检查"
    if ! wait_for_postgres; then
        echo -e "${RED}Postgres 未能启动，检查以上日志并修复后重试${NC}"
        exit 1
    fi

    echo "[*] 等待 Dendrite 就绪并检查"
    if ! wait_for_dendrite; then
        echo -e "${RED}Dendrite 未能启动，检查以上日志并修复后重试${NC}"
        exit 1
    fi

    echo "[6/7] 创建管理员账号"
    if docker-compose exec -T dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin >/dev/null 2>&1; then
        echo -e "${GREEN}管理员账号创建成功：${NC} $ADMIN_USER"
    else
        echo -e "${YELLOW}尝试创建管理员账号失败，可能已经存在或容器未完全就绪，打印最近日志：${NC}"
        docker-compose logs dendrite --tail=200 || true
    fi

    echo "[7/7] 配置 Nginx (HTTP)"
    NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
    cat > "$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGX
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" || \
        echo "⚠️ Certbot 证书申请失败，请检查域名解析"
    fi

    echo "======================================"
    echo "访问地址: $( [[ "$USE_LETSENCRYPT" == "yes" ]] && echo "https" || echo "http" )://$DOMAIN"
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "数据库密码: $DB_PASS"
    echo "======================================"

    echo -e "${GREEN}[安装完成]${NC}"
    check_service_status
}

reinstall_dendrite() {
    echo -e "${YELLOW}[开始重新安装 Dendrite]${NC}"
    read -p "重新安装将删除所有现有数据，是否继续? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消重新安装${NC}"
        return 0
    fi

    if [ -d "$BASE_DIR" ]; then
        BACKUP_DIR="${BASE_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo "- 备份现有配置到: $BACKUP_DIR"
        cp -r "$CONFIG_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
        (cd "$BASE_DIR" && docker-compose down -v) || true
    fi

    echo "- 清理旧目录"
    rm -rf "$BASE_DIR"
    install_dendrite
}

# 主循环
while true; do
    show_menu
    read -p "请选择操作 [0-2]: " choice
    case $choice in
        1) install_dendrite; break ;;
        2) reinstall_dendrite; break ;;
        0) echo -e "${BLUE}退出脚本${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择，请重新输入${NC}" ;;
    esac
done
