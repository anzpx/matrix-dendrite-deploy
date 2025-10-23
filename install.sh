 #!/bin/bash 
 set -euo pipefail
  
 # =========================
 # 常量定义 
 # ========================= 
 LOG_DIR="/opt/dendrite/logs"
 CONFIG_DIR="/opt/dendrite/config"
 DATA_DIR="/opt/dendrite/data"
 MEDIA_DIR="$DATA_DIR/media_store"
 CERT_DIR="/opt/dendrite/certs"
 INSTALL_LOG="$LOG_DIR/install.log"
  
 # 颜色输出 
 RED='\033[0;31m'
 GREEN='\033[0;32m'
 YELLOW='\033[1;33m'
 BLUE='\033[0;34m'
 NC='\033[0m' # No Color 
  
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
 # 核心功能
 # =========================
 check_service_status() {
     log_info "检查服务状态..."
     cd /opt/dendrite || { log_error "目录不存在"; return; }
     
     echo -e "${BLUE}容器状态:${NC}"
     docker-compose ps --color --no-trunc 2>/dev/null || log_warn "Docker Compose未运行"
     
     echo -e "${BLUE}PostgreSQL 日志 (最后20行):${NC}"
     docker-compose logs --tail=20 postgres 2>/dev/null || log_warn "PostgreSQL日志不可用"
     
     echo -e "${BLUE}Dendrite 日志 (最后30行):${NC}"
     docker-compose logs --tail=30 dendrite 2>/dev/null || log_warn "Dendrite日志不可用"
     
     echo -e "${BLUE}端口监听状态:${NC}"
 
 netstat -tlnp | grep -E ':(8008|8448|5432)' || log_warn "相关端口未监听"
 }
  
 wait_for_postgres() {
     log_info "等待 PostgreSQL 就绪..."
     local max_retries=12
     for ((i=1; i<=max_retries; i++)); do 
         if docker-compose exec -T postgres pg_isready -U dendrite -d dendrite >/dev/null 2>&1; then 
             log_success "PostgreSQL 已就绪"
             return
         fi 
         log_warn "尝试 $i/$max_retries - 等待 5 秒..."
         sleep 5 
     done
     log_error "PostgreSQL 启动超时"
     docker-compose logs postgres
     exit 1 
 }
  
 wait_for_dendrite() {
     log_info "等待 Dendrite 就绪..."
     local max_retries=15 
     for ((i=1; i<=max_retries; i++)); do
         if docker-compose exec -T dendrite curl -s http://localhost:7771/health >/dev/null; then
             log_success "Dendrite 已就绪"
             return
         fi 
         log_warn "尝试 $i/$max_retries - 等待 5 秒..."
         sleep 5
     done 
     log_error "Dendrite 启动超时"
     docker-compose logs dendrite 
     exit 1
 }
  
 generate_config() {
     local domain=$1 db_pass=$2 
     cat > "$CONFIG_DIR/dendrite.yaml" <<EOF
 global:
   server_name: $domain 
   private_key: /etc/dendrite/matrix_key.pem
  
 database:
   connection_string: postgres://dendrite:$db_pass@postgres:5432/dendrite?sslmode=disable 
  
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
     connection_string: postgres://dendrite:$db_pass@postgres:5432/dendrite?sslmode=disable
  
 logging:
 - type: file 
   level: info
   params:
     path: /var/log/dendrite.log
 EOF
 }
  
 # ========================= 
 # 安装流程
 # =========================
 install_dendrite() {
     # 初始化环境 
     mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$MEDIA_DIR" "$CERT_DIR"
     chmod 755 "$CONFIG_DIR" "$LOG_DIR"
     chmod 777 "$MEDIA_DIR"
     exec > >(tee -a "$INSTALL_LOG") 2>&1
  
     # 交互式配置 
     VPS_IP=$(curl -s ifconfig.me)
     read -p "请输入域名或 VPS IP (默认: $VPS_IP): " DOMAIN
     DOMAIN=${DOMAIN:-$VPS_IP}
  
     read -s -p "数据库密码 (回车自动生成): " DB_PASS 
     echo 
     DB_PASS=${DB_PASS:-$(openssl rand -base64 12)}
  
     read -p "管理员用户名 (回车自动生成): " ADMIN_USER 
     ADMIN_USER=${ADMIN_USER:-admin_$(openssl rand -hex 3)}
  
     read -s -p "管理员密码 (回车自动生成): " ADMIN_PASS 
     echo
     ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -base64 12)}
  
     # 证书检测 
     DNS_IP=$(dig +short "$DOMAIN" | head -n1)
     USE_LETSENCRYPT="no"
     if [[ "$DNS_IP" == "$VPS_IP" && "$DOMAIN" != "$VPS_IP" ]]; then
         log_success "域名解析验证通过，启用 Let's Encrypt"
         USE_LETSENCRYPT="yes"
     else
         log_warn "域名未解析到 $VPS_IP，使用自签名证书"
         DOMAIN="$VPS_IP"
     fi
  
     # 安装依赖
     log_info "安装系统依赖..."
     apt update -y
     apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx openssl dnsutils curl 
     systemctl enable --now docker
  
     # 密钥生成
     log_info "生成 Matrix 私钥..."
     openssl genpkey -algorithm ED25519 -out "$CONFIG_DIR/matrix_key.pem"
     chmod 600 "$CONFIG_DIR/matrix_key.pem"
  
     # 配置文件 
     generate_config "$DOMAIN" "$DB_PASS"
  
     # Docker Compose
     log_info "创建 Docker Compose 配置..."
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
       interval: 10s
       timeout: 5s 
       retries: 5 
  
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
     command: /usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml 
     restart: unless-stopped 
 EOF 
  
     # 启动服务 
     log_info "启动容器服务..."
     cd /opt/dendrite 
     docker-compose up -d 
     wait_for_postgres
     wait_for_dendrite 
  
     # 创建管理员
     log_info "创建管理员账号..."
     docker-compose exec -T dendrite \
         /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
 --username "$ADMIN_USER" --password "$ADMIN_PASS" --admin
  
     # Nginx 配置 
     log_info "配置 Nginx 反向代理..."
     cat > /etc/nginx/sites-available/dendrite.conf <<EOF 
 server {
     listen 80;
     server_name $DOMAIN;
     client_max_body_size 20M;
  
     location / {
         proxy_pass http://127.0.0.1:8008;
         proxy_set_header Host \$host;
         proxy_set_header X-Real-IP \$remote_addr;
         proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
         proxy_set_header X-Forwarded-Proto \$scheme;
     }
 }
 EOF
     ln -sf /etc/nginx/sites-available/dendrite.conf /etc/nginx/sites-enabled/
     rm -f /etc/nginx/sites-enabled/default 
     nginx -t && systemctl reload nginx
  
     # SSL 证书
     if [[ "$USE_LETSENCRYPT" == "yes" ]]; then 
         log_info "申请 Let's Encrypt 证书..."
         certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" \
             || log_warn "证书申请失败，请手动检查域名解析"
     fi 
  
     # 完成输出 
     cat <<EOF 
  
 ${GREEN}============ 部署成功 ============${NC}
 访问地址:   http${USE_LETSENCRYPT:+s}://$DOMAIN 
 管理员账号: $ADMIN_USER 
 管理员密码: $ADMIN_PASS
 数据库密码: $DB_PASS
 ${YELLOW}=================================${NC}
 EOF
     check_service_status 
 }
  
 reinstall_dendrite() {
     confirm_action "重新安装将删除所有数据，确认继续?" || return
     
     BACKUP_DIR="/opt/dendrite_backup_$(date +%s)"
     mkdir -p "$BACKUP_DIR"
     log_info "备份配置到 $BACKUP_DIR..."
     cp -r /opt/dendrite/config/* "$BACKUP_DIR/" 2>/dev/null || true 
     
     cd /opt/dendrite
     docker-compose down -v || true
     rm -rf /opt/dendrite
     install_dendrite
 }
  
 # ========================= 
 # 主菜单
 # =========================
 show_menu() {
     echo -e "${BLUE}======================================${NC}"
     echo -e "${BLUE}    Matrix Dendrite 自动部署脚本${NC}"
     echo -e "${BLUE}======================================${NC}"
     echo -e "${GREEN}1. 安装 Dendrite${NC}"
     echo -e "${YELLOW}2. 重新安装 Dendrite${NC}"
     echo -e "${RED}0. 退出${NC}"
     echo -e "${BLUE}======================================${NC}"
 }
  
 # =========================
 # 入口点 
 # ========================= 
 if [[ $EUID -ne 0 ]]; then 
     log_error "请使用 root 用户运行此脚本"
     exit 1
 fi
  
 while true; do 
     show_menu 
     read -p "请选择操作 [0-2]: " choice 
     case $choice in 
         1) install_dendrite; break ;;
         2) reinstall_dendrite; break ;;
         0) echo "退出"; exit 0 ;;
         *) log_warn "无效选择" ;;
     esac
 done
 
