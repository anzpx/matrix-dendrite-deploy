#!/bin/bash
set -euo pipefail  # 更严格的错误控制：exit on error, undefined var, pipefail
 
# =========================
# 常量定义
# =========================
 
LOG_DIR="/opt/dendrite/logs"
CONFIG_DIR="/opt/dendrite/config"
DATA_DIR="/opt/dendrite/data"
MEDIA_DIR="$DATA_DIR/media_store"
CERT_DIR="/opt/dendrite/certs"
 
# 颜色输出 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
 
# 日志文件
INSTALL_LOG="$LOG_DIR/install.log"
 
# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请以 root 用户或使用 sudo 执行此脚本${NC}"
    exit 1 
fi
 
# =========================
# 工具函数 
# =========================
 
log_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}
 
log_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}
 
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}
 
log_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}
 
confirm_action() {
    read -p "$1 (y/N): " choice
    [[ $choice =~ ^[Yy]$ ]] || return 1
}
 
# =========================
# 显示菜单 
# =========================
 
show_menu() {
    cat << EOF
 
${BLUE}======================================${NC}
${BLUE}    Matrix Dendrite 自动部署脚本${NC}
${BLUE}======================================${NC}
${GREEN}1. 安装 Dendrite${NC}
${YELLOW}2. 重新安装 Dendrite${NC}
${RED}0. 退出${NC}
${BLUE}======================================${NC}
 
EOF
}
 
# =========================
# 检查服务状态
# ========================= 
 
check_service_status() {
    log_info "检查当前服务状态..."
 
    if [[ ! -f /opt/dendrite/docker-compose.yml ]]; then
        log_warn "未找到 docker-compose 文件，可能尚未安装"
        return 
    fi
 
    cd /opt/dendrite || { log_error "无法进入 /opt/dendrite 目录"; return; }
 
    echo 
    echo -e "${BLUE}容器状态:${NC}"
    docker-compose ps --color --no-trunc
 
    echo
    echo -e "${BLUE}PostgreSQL 最近日志 (最后20行):${NC}"
    docker-compose logs --tail=20 postgres 2>/dev/null || echo "无日志或服务未启动"
 
    echo 
    echo -e "${BLUE}Dendrite 最近日志 (最后30行):${NC}"
    docker-compose logs --tail=30 dendrite 2>/dev/null || echo "无日志或服务未启动"
 
    echo
    echo -e "${BLUE}监听端口 (8008/8448/5432):${NC}"

netstat -tlnp | grep -E ':(8008|8448|5432)' || echo "无相关端口正在监听"
}
 
# =========================
# 等待 PostgreSQL 就绪
# =========================
 
wait_for_postgres() {
    log_info "等待 PostgreSQL 启动..."
    local retries=0 max_retries=30
    until docker-compose exec -T postgres pg_isready -U dendrite -d dendrite >/dev/null 2>&1; do
        ((retries++))
        if (( retries >= max_retries )); then
            log_error "PostgreSQL 启动超时，请查看日志:"
            docker-compose logs postgres 
            exit 1
        fi
        sleep 5
        echo "PostgreSQL 仍未就绪，等待中... ($retries/$max_retries)"
    done
    log_success "PostgreSQL 已准备就绪"
}
 
# =========================
# 等待 Dendrite 启动
# =========================
 
wait_for_dendrite() {
    log_info "等待 Dendrite 服务初始化..."
    local retries=0 max_retries=60
    until docker-compose exec -T dendrite curl -sf http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; do
        ((retries++))
        if (( retries >= max_retries )); then
            log_error "Dendrite 启动失败或响应异常，请检查日志:"
            docker-compose logs --tail=100 dendrite
            exit 1
        fi 
        sleep 5 
        echo "Dendrite 仍在启动中... ($retries/$max_retries)"
    done
    log_success "Dendrite API 可用"
}
 
# =========================
# 获取公网 IP
# ========================= 
 
get_public_ip() {
    timeout 10 curl -s https://ifconfig.me || \
    timeout 10 curl -s http://ip.sb || \
    log_error "无法获取公网 IP，请确保网络正常" && return 1
}
 
# =========================
# 安装 Dendrite 主函数
# =========================
 
install_dendrite() {
    local VPS_IP DOMAIN DB_PASS ADMIN_USER ADMIN_PASS USE_LETSENCRYPT="no"
 
    echo -e "${GREEN}[开始安装 Dendrite]${NC}"
 
    # 创建目录
    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$MEDIA_DIR" "$CERT_DIR"
    chmod 755 "$CONFIG_DIR" "$LOG_DIR"
    chmod 777 "$MEDIA_DIR"  # media_store 需要写入权限
 
    # 初始化日志流（追加模式）
    exec > >(tee -a "$INSTALL_LOG") 2>&1 
    echo "$(date '+%F %T') - 开始安装 Dendrite" | tee -a "$INSTALL_LOG"
 
    # ============= Step 1: 获取域名/IP =============
    VPS_IP=$(get_public_ip)
    if [[ -z "$VPS_IP" ]]; then
        log_error "无法获取公网 IP，终止安装"
        exit 1
    fi
    read -p "请输入域名或留空使用 VPS IP [$VPS_IP]: " input_domain
    DOMAIN="${input_domain:-$VPS_IP}"
 
    # ============= Step 2: 数据库密码 =============
    read -rs -p "请输入 PostgreSQL 密码（回车随机生成）: " db_pass_input 
    echo
    DB_PASS="${db_pass_input:-$(openssl rand -base64 12)}"
 
    # ============= Step 3: 管理员账户 =============
    read -p "请输入管理员用户名（回车随机生成）: " admin_user_input
    ADMIN_USER="${admin_user_input:-user_$(openssl rand -hex 5)}"
    
    read -rs -p "请输入管理员密码（回车随机生成）: " admin_pass_input
    echo
    ADMIN_PASS="${admin_pass_input:-$(openssl rand -base64 12)}"
 
    # 打印确认信息
    echo
    echo "✅ 使用以下配置进行安装:"
    echo "   域名/IP:       $DOMAIN"
    echo "   数据库密码:     [已隐藏]"
    echo "   管理员账号:     $ADMIN_USER"
    echo "   管理员密码:     [已隐藏]"
    echo "   存储路径:       /opt/dendrite"
    echo "   日志路径:       $INSTALL_LOG"
    echo "=========================================="
 
    # ============= Step 4: 安装依赖 =============
    log_info "更新系统并安装必要组件"
    apt update -qq
    apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl net-tools
    systemctl enable --now docker 
 
    # ============= Step 5: 检查 DNS 解析 =============
    if [[ "$DOMAIN" != "$VPS_IP" ]]; then
        local resolved_ip=$(dig +short "$DOMAIN" | head -n1)
        if [[ "$resolved_ip" == "$VPS_IP" ]]; then
            USE_LETSENCRYPT="yes"
            log_success "域名解析正确，将申请 Let's Encrypt 证书"
        else
            log_warn "域名未正确解析（期望 $VPS_IP，实际 $resolved_ip），改用自签名方案"
            DOMAIN="$VPS_IP"
        fi
    else 
        log_warn "使用 IP 地址，跳过 Let's Encrypt 证书申请"
    fi
 
    # ============= Step 6: 生成密钥 =============
    log_info "生成 ED25519 私钥"
    if [[ ! -f "$CONFIG_DIR/matrix_key.pem" ]]; then
        openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem"
        chmod 644 "$CONFIG_DIR/matrix_key.pem"
    else
        log_warn "已有 matrix_key.pem，跳过生成"
    fi 
 
    # ============= Step 7: 生成 dendrite.yaml =============
    log_info "创建 Dendrite 配置文件"
    cat > "$CONFIG_DIR/dendrite.yaml" << EOF 
global:
  server_name: $DOMAIN
  private_key: /etc/dendrite/matrix_key.pem
 
database:
  connection_string: "postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable"
 
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
    connection_string: "postgres://dendrite:$DB_PASS@postgres:5432/dendrite?sslmode=disable"
 
logging:
- type: file
    level: info
    params:
      path: /var/log/dendrite.log
 
# 推荐启用跨域支持
client_api:
  allow_origin_regexes:
- "^https?://.*\$"
EOF
 
    # ============= Step 8: docker-compose.yml =============
    log_info "生成 Docker Compose 配置"
    cat > /opt/dendrite/docker-compose.yml << EOF
version: '3.8'
 
services:
  postgres:
    image: postgres:15-alpine
    container_name: dendrite-postgres
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: dendrite
    volumes:
- ./data/postgres:/var/lib/postgresql/data
    ports:
- "127.0.0.1:5432:5432"
    restart: unless-stopped 
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite -d dendrite"]
      interval: 5s
      timeout: 5s
      retries: 10
 
  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    container_name: dendrite-monolith
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
- ./config:/etc/dendrite 
- ./logs:/var/log
- ./data/media_store:/etc/dendrite/media_store
    ports:
- "8008:8008"
- "8448:8448"
    command: >
      sh -c "
      /usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml &
      wait
      "
    restart: unless-stopped
EOF
 
    # ============= Step 9: 启动服务 =============
    log_info "启动 Docker 容器"
    cd /opt/dendrite || exit 1
    docker-compose down -v 2>/dev/null || true
    docker-compose up -d
 
    wait_for_postgres
    wait_for_dendrite
 
    # ============= Step 10: 创建管理员账号 =============
    log_info "创建管理员账号: $ADMIN_USER"
    if ! docker-compose exec -T dendrite \
        /usr/bin/create-account \
--config /etc/dendrite/dendrite.yaml \
--username "$ADMIN_USER" \
--password "$ADMIN_PASS" \
--admin; then
        log_warn "账号创建失败，可能是重复执行导致用户已存在"
    fi
 
    # ============= Step 11: Nginx 配置 =============
    log_info "配置 Nginx 反向代理"
    local NGINX_CONF="/etc/nginx/sites-available/dendrite.conf"
    cat > "$NGINX_CONF" << NGINX_EOF
server {
    listen 80;
    server_name $DOMAIN;
 
    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        client_max_body_size 50M;
    }
 
    location / {
        return 301 https://\$host;
    }
}
NGINX_EOF 
 
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx || { log_error "Nginx 配置测试失败"; exit 1; }
 
    # ============= Step 12: 申请 HTTPS 证书 =============
    if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
        log_info "正在为 $DOMAIN 申请 Let's Encrypt 证书"
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" --redirect || \
        log_warn "证书申请失败，请检查防火墙、DNS 和 80/443 端口开放情况"
    else 
        log_warn "未启用 HTTPS，建议通过反向代理添加 SSL 或绑定域名"
    fi
 
    # ============= 安装完成 =============
    echo
    echo -e "${GREEN}✅ Dendrite 安装成功！${NC}"
    echo "=========================================="
    echo "🌐 访问地址: $( [[ "$USE_LETSENCRYPT" == "yes" ]] && echo "https" || echo "http" )://$DOMAIN"
    echo "👤 管理员账号: $ADMIN_USER"
    echo "🔑 管理员密码: $ADMIN_PASS"
    echo "💾 数据目录: /opt/dendrite"
    echo "📄 日志文件: $INSTALL_LOG"
    echo "💡 提示：可通过 'docker-compose -f /opt/dendrite/docker-compose.yml logs -f' 查看实时日志"
    echo "=========================================="
 
    check_service_status
}
 
# =========================
# 重新安装函数
# =========================
 
reinstall_dendrite() {
    echo -e "${YELLOW}[⚠️ 开始重新安装 Dendrite]${NC}"
    confirm_action "⚠️ 此操作将删除所有数据，是否继续？" || return
 
    local BACKUP_DIR=""
    if [[ -d "/opt/dendrite" ]]; then
        BACKUP_DIR="/opt/dendrite_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        log_info "备份现有配置至: $BACKUP_DIR"
        cp -r /opt/dendrite/config/. "$BACKUP_DIR/" 2>/dev/null || true
        cd /opt/dendrite && docker-compose down -v || true
    fi
 
    log_info "清理旧环境"
    rm -rf /opt/dendrite
 
    log_info "执行全新安装"
    install_dendrite
}
 
# =========================
# 主循环
# =========================
 
while true; do
    show_menu 
    read -rp "请选择操作 [0-2]: " choice
    case $choice in
        1)
            install_dendrite 
            break
            ;;
        2)
            reinstall_dendrite 
            break
            ;;
       

以上内容由AI搜集并生成，仅供参考
