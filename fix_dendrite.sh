#!/bin/bash
set -e

# -------------------------------
# 配置变量
# -------------------------------
INSTALL_DIR="/opt/dendrite"
WEB_DIR="/opt/element-web"
CADDY_DIR="/opt/caddy"
BACKUP_DIR="$INSTALL_DIR/backups"
DOCKER_COMPOSE_FILE="/opt/docker-compose.yml"
LOG_FILE="/var/log/dendrite-deploy.log"

# -------------------------------
# 颜色输出函数
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[警告]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[错误]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[信息]${NC} $1" | tee -a "$LOG_FILE"
}

# -------------------------------
# 改进的服务检查函数
# -------------------------------
wait_for_service() {
    local service=$1
    local max_attempts=40  # 增加等待次数
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        # 使用更可靠的状态检查方法
        if docker compose -f "$DOCKER_COMPOSE_FILE" ps "$service" 2>/dev/null | grep -q "Up"; then
            # 额外的健康检查
            if [[ "$service" == "postgres" ]]; then
                if docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
                    log "服务 $service 已启动并就绪"
                    return 0
                fi
            elif [[ "$service" == "dendrite" ]]; then
                # 尝试访问 Dendrite 的健康端点
                if docker exec dendrite_server curl -s -f http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
                    log "服务 $service 已启动并就绪"
                    return 0
                fi
            else
                log "服务 $service 已启动"
                return 0
            fi
        fi
        
        warn "等待服务 $service 启动... ($attempt/$max_attempts)"
        sleep 10  # 增加等待时间
        ((attempt++))
    done
    
    error "服务 $service 启动超时"
    
    # 显示服务日志以帮助诊断
    error "服务 $service 的日志："
    docker compose -f "$DOCKER_COMPOSE_FILE" logs --tail=20 "$service" || true
    
    return 1
}

# 先运行这些诊断命令来检查当前状态
diagnose_problem() {
    log "开始诊断问题..."
    
    echo
    echo "=== 当前容器状态 ==="
    docker ps -a
    
    echo
    echo "=== Dendrite 日志 ==="
    docker logs dendrite_server --tail=50 2>/dev/null || echo "Dendrite 容器不存在"
    
    echo
    echo "=== PostgreSQL 日志 ==="
    docker logs dendrite_postgres --tail=30 2>/dev/null || echo "PostgreSQL 容器不存在"
    
    echo
    echo "=== 磁盘空间 ==="
    df -h
    
    echo
    echo "=== 内存使用 ==="
    free -h
}

# 改进的启动服务函数
start_services_improved() {
    log "启动服务 (改进版本)..."
    
    # 先只启动 PostgreSQL 并等待它完全就绪
    info "第一步：启动 PostgreSQL..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d postgres
    
    if ! wait_for_service postgres; then
        error "PostgreSQL 启动失败，无法继续"
        diagnose_problem
        return 1
    fi
    
    # 给 PostgreSQL 更多时间初始化
    info "等待 PostgreSQL 完全初始化..."
    sleep 20
    
    # 检查数据库连接
    info "测试数据库连接..."
    if ! docker exec dendrite_postgres psql -U dendrite -d dendrite -c "SELECT 1;" >/dev/null 2>&1; then
        error "数据库连接测试失败"
        diagnose_problem
        return 1
    fi
    
    # 现在启动其他服务
    info "第二步：启动其他服务..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    
    # 等待服务启动
    info "等待服务启动..."
    
    if ! wait_for_service dendrite; then
        warn "Dendrite 启动较慢，继续等待其他服务..."
    fi
    
    wait_for_service element-web || warn "Element Web 启动警告"
    wait_for_service caddy || warn "Caddy 启动警告"
    
    log "服务启动流程完成"
}

# 改进的安装函数
install_dendrite_improved() {
    log "开始安装 Matrix Dendrite (改进版本)..."
    
    # 获取服务器地址
    PUBLIC_IP=$(curl -fsSL -4 ifconfig.me 2>/dev/null || curl -fsSL -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    if [[ -z "$PUBLIC_IP" ]]; then
        read -p "无法获取公网 IP，请手动输入服务器公网 IP 或域名: " PUBLIC_IP
    fi

    read -p "请输入域名（回车使用 IP: ${PUBLIC_IP}）: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$PUBLIC_IP}
    
    if [[ -z "$SERVER_NAME" ]]; then
        error "服务器地址不能为空"
        return 1
    fi
    
    info "使用地址: $SERVER_NAME"
    
    # 创建目录
    mkdir -p "$INSTALL_DIR"/{config,pgdata,logs} "$WEB_DIR" "$CADDY_DIR"/{data,config} "$BACKUP_DIR"
    
    # 安装依赖
    if ! command -v docker &>/dev/null; then
        log "安装 Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    
    if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
        log "安装 Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi
    
    # 生成密码
    ADMIN_USER="admin"
    ADMIN_PASS=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)
    PGPASS=$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    
    info "管理员账号: $ADMIN_USER"
    info "管理员密码: $ADMIN_PASS"
    
    # 生成配置文件
    generate_configs_improved || return 1
    
    # 使用改进的启动方法
    start_services_improved || return 1
    
    # 创建管理员账户
    create_admin_user_improved || return 1
    
    show_success_message_improved
}

generate_configs_improved() {
    log "生成配置文件..."
    
    # 生成简化的 docker-compose.yml (去掉 version 字段)
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
services:
  postgres:
    container_name: dendrite_postgres
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: "${PGPASS}"
      POSTGRES_DB: dendrite
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --lc-collate=C --lc-ctype=C"
    volumes:
      - $INSTALL_DIR/pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  dendrite:
    container_name: dendrite_server
    image: matrixdotorg/dendrite-monolith:latest
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - $INSTALL_DIR/config:/etc/dendrite
    environment:
      - DENDRITE_CONFIG=/etc/dendrite/dendrite.yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8008/_matrix/client/versions || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 60s

  element-web:
    container_name: element_web
    image: vectorim/element-web:latest
    restart: unless-stopped
    volumes:
      - $WEB_DIR/config.json:/app/config.json

  caddy:
    container_name: caddy_proxy
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile
      - $CADDY_DIR/data:/data
      - $CADDY_DIR/config:/config
    depends_on:
      - dendrite
      - element-web
EOF

    # 生成 Caddyfile
    if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        TLS_MODE="internal"
        warn "使用 IP 地址，将使用自签名证书"
    else
        TLS_MODE="acme"
        info "使用域名，将使用 Let's Encrypt 证书"
    fi

    cat > "$CADDY_DIR/Caddyfile" <<EOF
{
    email admin@${SERVER_NAME}
}

${SERVER_NAME} {
    encode gzip
    tls ${TLS_MODE}

    # Element Web 前端
    handle / {
        reverse_proxy element-web:80
    }

    # Client-Server API
    handle /_matrix/client/* {
        reverse_proxy dendrite:8008
    }

    # Server-Server API  
    handle /_matrix/federation/* {
        reverse_proxy dendrite:8448
    }
}
EOF

    # Element-Web 配置
    cat > "$WEB_DIR/config.json" <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${SERVER_NAME}",
            "server_name": "${SERVER_NAME}"
        }
    },
    "brand": "Element"
}
EOF

    # 生成密钥和证书
    log "生成 TLS 证书..."
    if [[ ! -f "$INSTALL_DIR/config/matrix_key.pem" ]]; then
        docker run --rm --entrypoint="/usr/bin/generate-keys" \
            -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
            -private-key /mnt/matrix_key.pem \
            -tls-cert /mnt/server.crt \
            -tls-key /mnt/server.key
    fi

    # 生成 dendrite.yaml 配置
    log "生成 Dendrite 配置..."
    if [[ ! -f "$INSTALL_DIR/config/dendrite.yaml" ]]; then
        docker run --rm --entrypoint="/usr/bin/generate-config" \
            -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
            -dir /etc/dendrite \
            -db "postgres://dendrite:${PGPASS}@postgres/dendrite?sslmode=disable" \
            -server "${SERVER_NAME}" \
            > "$INSTALL_DIR/config/dendrite.yaml"
        
        # 启用开放注册以便测试
        sed -i 's/registration_requires_token: true/registration_requires_token: false/' "$INSTALL_DIR/config/dendrite.yaml"
    fi
}

create_admin_user_improved() {
    log "创建管理员账户..."
    
    # 等待更长时间确保 Dendrite 完全启动
    info "等待 Dendrite 完全启动..."
    sleep 30
    
    local max_attempts=5
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if docker exec dendrite_server /usr/bin/create-account \
            -config /etc/dendrite/dendrite.yaml \
            -username "$ADMIN_USER" \
            -password "$ADMIN_PASS" \
            -admin >> "$LOG_FILE" 2>&1; then
            log "管理员账户创建成功"
            return 0
        fi
        
        warn "管理员账户创建尝试失败 ($attempt/$max_attempts)，重试..."
        sleep 10
        ((attempt++))
    done
    
    warn "管理员账户创建失败，可能需要手动创建"
    return 1
}

show_success_message_improved() {
    echo
    echo "======================================"
    echo "安装完成！"
    echo "======================================"
    echo "访问地址: https://${SERVER_NAME}"
    echo "管理员账号: ${ADMIN_USER}"
    echo "管理员密码: ${ADMIN_PASS}"
    echo
    echo "如果无法访问，请检查："
    echo "1. 防火墙设置（确保 80 和 443 端口开放）"
    echo "2. 查看服务状态: docker compose -f $DOCKER_COMPOSE_FILE ps"
    echo "3. 查看日志: docker compose -f $DOCKER_COMPOSE_FILE logs -f"
    echo "======================================"
}

# 主菜单
main_menu() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 一键部署脚本 (修复版)"
    echo "======================================"
    echo
    echo "请选择操作："
    echo "1) 安装/部署 Matrix Dendrite (修复版)"
    echo "2) 诊断当前问题"
    echo "3) 查看服务状态"
    echo "4) 查看服务日志"
    echo "5) 完全卸载"
    echo "0) 退出"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) install_dendrite_improved ;;
        2) diagnose_problem ;;
        3) docker compose -f "$DOCKER_COMPOSE_FILE" ps ;;
        4) 
            echo "选择要查看的日志："
            echo "1) Dendrite"
            echo "2) PostgreSQL" 
            echo "3) Caddy"
            echo "4) 所有服务"
            read -p "请输入数字: " log_choice
            case "$log_choice" in
                1) docker compose -f "$DOCKER_COMPOSE_FILE" logs dendrite ;;
                2) docker compose -f "$DOCKER_COMPOSE_FILE" logs postgres ;;
                3) docker compose -f "$DOCKER_COMPOSE_FILE" logs caddy ;;
                4) docker compose -f "$DOCKER_COMPOSE_FILE" logs ;;
            esac
            ;;
        5) 
            if confirm "确定要完全卸载并删除所有数据吗？"; then
                docker compose -f "$DOCKER_COMPOSE_FILE" down -v
                rm -rf "$INSTALL_DIR" "$WEB_DIR" "$CADDY_DIR" "$DOCKER_COMPOSE_FILE"
                log "卸载完成"
            fi
            ;;
        0) echo "退出脚本"; exit 0 ;;
        *) error "无效选项" ;;
    esac
}

# 确认函数
confirm() {
    read -p "$1 (y/N): " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) echo "操作已取消"; return 1 ;;
    esac
}

# 脚本入口
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log "脚本开始执行"
main_menu
