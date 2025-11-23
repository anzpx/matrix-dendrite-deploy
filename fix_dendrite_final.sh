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
# 清理函数
# -------------------------------
cleanup_containers() {
    log "清理所有相关容器..."
    
    # 停止并删除所有 Dendrite 相关容器
    docker stop dendrite_server dendrite_postgres element_web caddy_proxy 2>/dev/null || true
    docker rm dendrite_server dendrite_postgres element_web caddy_proxy 2>/dev/null || true
    
    # 停止并删除旧的容器（使用不同命名）
    docker stop dendrite-dendrite-1 dendrite-postgres-1 2>/dev/null || true
    docker rm dendrite-dendrite-1 dendrite-postgres-1 2>/dev/null || true
    
    # 清理 Docker 网络和卷
    docker network prune -f 2>/dev/null || true
}

cleanup_files() {
    log "清理配置文件..."
    
    # 备份重要数据
    if [ -d "$INSTALL_DIR/pgdata" ]; then
        mkdir -p "$BACKUP_DIR"
        tar -czf "$BACKUP_DIR/pgdata_backup_$(date +%Y%m%d_%H%M%S).tar.gz" -C "$INSTALL_DIR" pgdata 2>/dev/null || true
    fi
    
    # 删除配置目录
    rm -rf "$INSTALL_DIR/config" "$WEB_DIR" "$CADDY_DIR"
    
    # 重新创建目录结构
    mkdir -p "$INSTALL_DIR"/{config,logs} "$WEB_DIR" "$CADDY_DIR"/{data,config} "$BACKUP_DIR"
}

check_ports() {
    log "检查端口占用情况..."
    
    local ports=(8008 8448 5432 80 443)
    for port in "${ports[@]}"; do
        if netstat -tulpn | grep ":$port " >/dev/null; then
            warn "端口 $port 被占用:"
            netstat -tulpn | grep ":$port "
        else
            log "端口 $port 空闲"
        fi
    done
}

# -------------------------------
# 修复安装函数
# -------------------------------
fix_installation() {
    log "开始修复安装..."
    
    # 获取服务器地址
    PUBLIC_IP="38.47.238.148"  # 使用您的实际IP
    SERVER_NAME="$PUBLIC_IP"
    
    info "使用地址: $SERVER_NAME"
    
    # 清理现有环境
    cleanup_containers
    cleanup_files
    check_ports
    
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
    
    # 生成简化的 docker-compose.yml
    generate_simple_compose || return 1
    
    # 生成配置文件
    generate_simple_configs || return 1
    
    # 分步启动服务
    start_services_step_by_step || return 1
    
    show_success_message
}

generate_simple_compose() {
    log "生成简化版 Docker Compose 配置..."
    
    cat > "$DOCKER_COMPOSE_FILE" <<'EOF'
services:
  postgres:
    image: postgres:15-alpine
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: ${PGPASS}
      POSTGRES_DB: dendrite
    volumes:
      - /opt/dendrite/pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite"]
      interval: 10s
      timeout: 5s
      retries: 5

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    container_name: dendrite_server
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - /opt/dendrite/config:/etc/dendrite
    environment:
      - DENDRITE_CONFIG=/etc/dendrite/dendrite.yaml
    # 不暴露端口，通过 Caddy 反向代理访问

  element-web:
    image: vectorim/element-web:latest
    container_name: element_web
    restart: unless-stopped
    volumes:
      - /opt/element-web/config.json:/app/config.json

  caddy:
    image: caddy:2-alpine
    container_name: caddy_proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/caddy/Caddyfile:/etc/caddy/Caddyfile
      - /opt/caddy/data:/data
      - /opt/caddy/config:/config
    depends_on:
      - dendrite
      - element-web
EOF

    # 替换密码变量
    sed -i "s/\${PGPASS}/$PGPASS/g" "$DOCKER_COMPOSE_FILE"
}

generate_simple_configs() {
    log "生成简化配置文件..."
    
    # 生成 Caddyfile
    cat > "$CADDY_DIR/Caddyfile" <<EOF
${SERVER_NAME} {
    tls internal
    
    reverse_proxy /_matrix/* dendrite:8008
    reverse_proxy /_matrix/federation/* dendrite:8448
    reverse_proxy /* element-web:80
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

    # 生成 Dendrite 配置
    log "生成 Dendrite 配置和密钥..."
    
    # 生成密钥
    docker run --rm --entrypoint="/usr/bin/generate-keys" \
        -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
        -private-key /mnt/matrix_key.pem \
        -tls-cert /mnt/server.crt \
        -tls-key /mnt/server.key

    # 生成基础配置
    docker run --rm --entrypoint="/usr/bin/generate-config" \
        -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
        -dir /etc/dendrite \
        -db "postgres://dendrite:${PGPASS}@postgres/dendrite?sslmode=disable" \
        -server "${SERVER_NAME}" \
        > "$INSTALL_DIR/config/dendrite.yaml"

    # 修复配置路径
    sed -i 's#/var/dendrite#/etc/dendrite#g' "$INSTALL_DIR/config/dendrite.yaml"
    
    # 启用开放注册
    sed -i 's/registration_requires_token: true/registration_requires_token: false/' "$INSTALL_DIR/config/dendrite.yaml"
    
    # 禁用邮件通知（简化配置）
    sed -i 's/^    smtp:/    # smtp:/' "$INSTALL_DIR/config/dendrite.yaml"
    sed -i 's/^      enable:/      # enable:/' "$INSTALL_DIR/config/dendrite.yaml"
}

start_services_step_by_step() {
    log "分步启动服务..."
    
    # 第一步：启动 PostgreSQL
    info "启动 PostgreSQL..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d postgres
    
    # 等待 PostgreSQL 完全就绪
    info "等待 PostgreSQL 启动..."
    local pg_attempt=1
    while [[ $pg_attempt -le 30 ]]; do
        if docker compose -f "$DOCKER_COMPOSE_FILE" ps postgres | grep -q "Up" && \
           docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
            log "PostgreSQL 已就绪"
            break
        fi
        warn "等待 PostgreSQL... ($pg_attempt/30)"
        sleep 5
        ((pg_attempt++))
    done
    
    if [[ $pg_attempt -gt 30 ]]; then
        error "PostgreSQL 启动失败"
        docker compose -f "$DOCKER_COMPOSE_FILE" logs postgres
        return 1
    fi
    
    # 第二步：启动 Dendrite
    info "启动 Dendrite..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d dendrite
    
    # 等待 Dendrite 启动
    info "等待 Dendrite 启动..."
    local dendrite_attempt=1
    while [[ $dendrite_attempt -le 40 ]]; do
        if docker compose -f "$DOCKER_COMPOSE_FILE" ps dendrite | grep -q "Up"; then
            # 检查 Dendrite 是否真正响应
            if docker exec dendrite_server curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
                log "Dendrite 已就绪"
                break
            fi
        fi
        warn "等待 Dendrite... ($dendrite_attempt/40)"
        sleep 10
        ((dendrite_attempt++))
    done
    
    if [[ $dendrite_attempt -gt 40 ]]; then
        warn "Dendrite 启动较慢，继续其他服务启动..."
        docker compose -f "$DOCKER_COMPOSE_FILE" logs dendrite --tail=20
    fi
    
    # 第三步：启动其他服务
    info "启动 Element Web 和 Caddy..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d element-web caddy
    
    # 等待所有服务
    sleep 10
    
    log "所有服务启动完成"
}

create_admin_user_simple() {
    log "创建管理员账户..."
    
    # 等待 Dendrite 完全就绪
    sleep 20
    
    local attempt=1
    while [[ $attempt -le 10 ]]; do
        if docker exec dendrite_server /usr/bin/create-account \
            -config /etc/dendrite/dendrite.yaml \
            -username "$ADMIN_USER" \
            -password "$ADMIN_PASS" \
            -admin >> "$LOG_FILE" 2>&1; then
            log "管理员账户创建成功"
            return 0
        fi
        warn "创建管理员账户失败，重试... ($attempt/10)"
        sleep 10
        ((attempt++))
    done
    
    warn "管理员账户创建失败，请手动创建"
    return 1
}

show_success_message() {
    echo
    echo "======================================"
    echo "修复安装完成！"
    echo "======================================"
    echo "访问地址: https://${SERVER_NAME}"
    echo "管理员账号: ${ADMIN_USER}"
    echo "管理员密码: ${ADMIN_PASS}"
    echo
    echo "如果无法访问，请运行以下命令检查状态:"
    echo "docker compose -f $DOCKER_COMPOSE_FILE ps"
    echo "docker compose -f $DOCKER_COMPOSE_FILE logs"
    echo "======================================"
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 修复脚本"
    echo "======================================"
    echo
    echo "请选择操作："
    echo "1) 修复安装（清理后重新安装）"
    echo "2) 仅清理容器和配置"
    echo "3) 检查服务状态"
    echo "4) 查看服务日志"
    echo "5) 创建管理员账户"
    echo "0) 退出"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) fix_installation ;;
        2) 
            cleanup_containers
            cleanup_files
            log "清理完成"
            ;;
        3) 
            echo "=== 容器状态 ==="
            docker ps -a | grep -E "(dendrite|postgres|element|caddy)"
            echo
            echo "=== 端口占用 ==="
            netstat -tulpn | grep -E ':(80|443|8008|8448|5432)' || echo "相关端口未占用"
            ;;
        4)
            echo "选择要查看的日志："
            echo "1) Dendrite"
            echo "2) PostgreSQL"
            echo "3) Caddy"
            echo "4) 所有服务"
            read -p "请输入数字: " log_choice
            case "$log_choice" in
                1) docker logs dendrite_server --tail=50 2>/dev/null || echo "Dendrite 容器不存在" ;;
                2) docker logs dendrite_postgres --tail=30 2>/dev/null || echo "PostgreSQL 容器不存在" ;;
                3) docker logs caddy_proxy --tail=30 2>/dev/null || echo "Caddy 容器不存在" ;;
                4) docker compose -f "$DOCKER_COMPOSE_FILE" logs --tail=30 2>/dev/null || echo "Docker Compose 文件不存在" ;;
            esac
            ;;
        5) create_admin_user_simple ;;
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
