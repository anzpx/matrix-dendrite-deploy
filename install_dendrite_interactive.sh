#!/bin/bash
set -e

# --------------- 配置区域 ----------------
LOG_DIR="/opt/dendrite/logs"
CONFIG_DIR="/opt/dendrite/config"
DATA_DIR="/opt/dendrite/data"
CERT_DIR="/opt/dendrite/certs"

# 保留日志天数
LOG_KEEP_DAYS=7

# 智能等待最长秒数与间隔
MAX_WAIT=120
SLEEP_INTERVAL=5

# --------------- 颜色 ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --------------- 菜单 ----------------
show_menu() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}    Matrix Dendrite 部署脚本${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}1. 安装 Dendrite${NC}"
    echo -e "${YELLOW}2. 重新安装 Dendrite${NC}"
    echo -e "${RED}0. 退出${NC}"
    echo -e "${BLUE}======================================${NC}"
}

# --------------- 日志清理 ----------------
cleanup_logs() {
    echo -e "${YELLOW}清理 $LOG_KEEP_DAYS 天以前的旧日志...${NC}"
    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -type f -mtime +$LOG_KEEP_DAYS -exec rm -f {} \; || true
}

# --------------- 服务状态检查 ----------------
check_service_status() {
    echo -e "${YELLOW}检查服务状态...${NC}"
    cd /opt/dendrite || return

    echo -e "${BLUE}容器状态:${NC}"
    docker-compose ps || true

    echo -e "${BLUE}PostgreSQL 日志 (最后20行):${NC}"
    if docker-compose ps -q postgres &>/dev/null; then
        docker-compose logs postgres --tail=20 || true
    else
        echo "postgres 服务未启动"
    fi

    echo -e "${BLUE}Dendrite 日志 (最后30行):${NC}"
    if docker-compose ps -q dendrite &>/dev/null; then
        docker-compose logs dendrite --tail=30 || true
    else
        echo "dendrite 服务未启动"
    fi

    echo -e "${BLUE}端口监听状态:${NC}"
    netstat -tlnp | grep -E ':(8008|8448|5432)' || echo "相关端口未监听"
}

# --------------- 后台实时监控（即时重启） ----------------
monitor_containers() {
    # 以后台方式运行，检测异常则 restart
    echo -e "${YELLOW}启动后台监控 (实时重启停止容器)...${NC}"
    (
        cd /opt/dendrite || exit 0
        while true; do
            for svc in postgres dendrite; do
                CID=$(docker-compose ps -q "$svc" 2>/dev/null || true)
                if [ -n "$CID" ]; then
                    STATUS=$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo "not_found")
                else
                    STATUS="not_found"
                fi

                if [[ "$STATUS" != "running" && "$STATUS" != "not_found" ]]; then
                    echo -e "${RED}检测到服务 $svc 状态: $STATUS，自动重启 $svc ...${NC}"
                    docker-compose restart "$svc" || docker-compose up -d "$svc" || true
                fi
            done
            sleep 30
        done
    ) & disown
}

# --------------- 每日 Cron 监控脚本（重启异常容器） ----------------
setup_cron_monitor() {
    CRON_CMD="bash /opt/dendrite/monitor.sh"
    MONITOR_SCRIPT="/opt/dendrite/monitor.sh"

    cat > "$MONITOR_SCRIPT" <<'EOF'
#!/bin/bash
cd /opt/dendrite || exit 0
for svc in postgres dendrite; do
    CID=$(docker-compose ps -q "$svc" 2>/dev/null || true)
    if [ -n "$CID" ]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo "not_found")
    else
        STATUS="not_found"
    fi
    if [[ "$STATUS" != "running" && "$STATUS" != "not_found" ]]; then
        docker-compose restart "$svc" || docker-compose up -d "$svc" || true
    fi
done
EOF

    chmod +x "$MONITOR_SCRIPT"

    # 添加到 crontab（每天 0 点）
    (crontab -l 2>/dev/null | grep -v -F "$MONITOR_SCRIPT" || true; echo "0 0 * * * $MONITOR_SCRIPT >/dev/null 2>&1") | crontab -
    echo -e "${GREEN}✅ 已添加每日自动检查容器任务 (cron)${NC}"
}

# --------------- 安装主流程 ----------------
install_dendrite() {
    echo -e "${GREEN}[开始安装 Dendrite]${NC}"

    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$DATA_DIR/postgres" "$DATA_DIR/media_store" "$CERT_DIR"
    exec > >(tee -a "$LOG_DIR/install.log") 2>&1

    VPS_IP=$(curl -s ifconfig.me || echo "")
    read -p "请输入域名或 VPS IP (回车自动使用 VPS IP: ${VPS_IP:-127.0.0.1}): " DOMAIN
    DOMAIN=${DOMAIN:-${VPS_IP:-127.0.0.1}}

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
    echo "域名/IP: $DOMAIN"
    echo "数据库密码: $DB_PASS"
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "======================================"

    if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        echo -e "${RED}脚本仅支持 Ubuntu 系统${NC}"
        exit 1
    fi

    echo "[1/7] 安装 Docker / Docker Compose / Nginx / Certbot / dnsutils"
    apt update -y
    apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl
    systemctl enable --now docker

    DNS_IP=$(dig +short "$DOMAIN" | head -n1 || echo "")
    USE_LETSENCRYPT="no"
    if [[ -n "$DNS_IP" && "$DNS_IP" == "$VPS_IP" && "$DOMAIN" != "$VPS_IP" ]]; then
        echo "✅ 域名解析正确，启用 Let's Encrypt"
        USE_LETSENCRYPT="yes"
    else
        echo "⚠️ 域名未解析到 VPS 公网 IP，将使用 VPS IP 或自签名证书"
        DOMAIN="$VPS_IP"
    fi

    chown -R "$(whoami):$(whoami)" "/opt/dendrite"
    chmod -R 755 "$CONFIG_DIR"

    echo "[2/7] 生成 Dendrite 私钥 (Ed25519)"
    openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem" || true
    chmod 644 "$CONFIG_DIR/matrix_key.pem" || true

    echo "[3/7] 创建 Dendrite 配置文件"
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

    echo "[4/7] 创建 Docker Compose 文件"
    cat > /opt/dendrite/docker-compose.yml <<EOF
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
      test: ["CMD-SHELL", "pg_isready -U dendrite -d dendrite"]
      interval: 5s
      timeout: 5s
      retries: 10

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
      - ./data/media_store:/etc/dendrite/media_store
      - ./logs:/var/log
    command: >
      /usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml
    restart: unless-stopped
EOF

    echo "[5/7] 启动服务"
    cd /opt/dendrite || return
    docker-compose down -v || true
    docker-compose up -d

    echo "开始智能等待 Dendrite 健康并创建管理员账号..."
    ACCOUNT_CREATED=0
    ELAPSED=0

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        CID=$(docker-compose ps -q dendrite 2>/dev/null || true)
        HEALTH=$( [ -n "$CID" ] && docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo "none")

        if [ "$HEALTH" == "healthy" ]; then
            echo "容器健康，尝试创建管理员账号..."
            #  尝试创建账号（如果容器内命令路径不同，可能需手动执行）
            if docker-compose exec -T dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin 2>/dev/null; then
                echo -e "${GREEN}✅ 管理员账号创建成功${NC}"
                ACCOUNT_CREATED=1
                break
            else
                echo "账号创建尝试失败 — 服务可能刚刚就绪，等待 $SLEEP_INTERVAL 秒重试..."
            fi
        else
            echo "当前 Dendrite 健康状态: ${HEALTH:-unknown}，等待 $SLEEP_INTERVAL 秒..."
        fi

        sleep $SLEEP_INTERVAL
        ELAPSED=$((ELAPSED + SLEEP_INTERVAL))

        if [ $ELAPSED -eq 30 ] || [ $ELAPSED -eq 60 ]; then
            echo -e "${YELLOW}中间检查点 - 当前服务状态:${NC}"
            docker-compose ps || true
            docker-compose logs dendrite --tail=10 || true
        fi
    done

    if [ $ACCOUNT_CREATED -eq 0 ]; then
        echo -e "${YELLOW}⚠️ 管理员账号创建失败，输出完整日志以便排查${NC}"
        echo -e "${BLUE}Dendrite 容器完整日志:${NC}"
        docker-compose logs dendrite || echo "dendrite 未启动"
        echo -e "${BLUE}PostgreSQL 容器完整日志:${NC}"
        docker-compose logs postgres || echo "postgres 未启动"
        echo -e "${YELLOW}请手动创建管理员账号:${NC}"
        echo "cd /opt/dendrite && docker-compose exec dendrite /usr/bin/create-account --config /etc/dendrite/dendrite.yaml --username \"$ADMIN_USER\" --password \"$ADMIN_PASS\" --admin"
    fi

    echo "[6/7] 配置 Nginx"
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
        echo "申请 Let's Encrypt SSL 证书..."
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" || echo "Certbot 证书申请失败，请检查域名解析"
    fi

    echo "======================================"
    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        echo "访问地址: https://$DOMAIN"
    else
        echo "HTTP 地址: http://$DOMAIN"
    fi
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "数据库密码: $DB_PASS"
    echo "======================================"

    # 清理旧日志、输出状态、启动后台监控与设置 cron
    cleanup_logs
    check_service_status
    monitor_containers
    setup_cron_monitor

    echo -e "${GREEN}[安装完成]${NC}"
}

# --------------- 重新安装 ----------------
reinstall_dendrite() {
    echo -e "${YELLOW}[开始重新安装 Dendrite]${NC}"
    read -p "重新安装将删除所有现有数据，是否继续? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消重新安装${NC}"
        return
    fi

    if [ -d "/opt/dendrite" ]; then
        BACKUP_DIR="/opt/dendrite_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo "备份现有配置到: $BACKUP_DIR"
        cp -r /opt/dendrite/config/* "$BACKUP_DIR/" 2>/dev/null || true
        echo "停止并删除现有容器..."
        cd /opt/dendrite || true
        docker-compose down -v || true
    fi

    echo "清理旧数据..."
    cd /opt || true
    rm -rf dendrite

    install_dendrite
}

# --------------- 主循环 ----------------
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
