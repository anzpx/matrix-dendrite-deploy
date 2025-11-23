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
# 密码修复函数
# -------------------------------
fix_password_issue() {
    log "修复数据库密码问题..."
    
    # 停止所有服务
    docker compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true
    
    # 生成新密码
    NEW_PGPASS=$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    info "新数据库密码: $NEW_PGPASS"
    
    # 更新 docker-compose.yml 中的密码
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        sed -i "s/POSTGRES_PASSWORD:.*/POSTGRES_PASSWORD: \"${NEW_PGPASS}\"/g" "$DOCKER_COMPOSE_FILE"
        log "更新 docker-compose.yml 密码"
    fi
    
    # 更新 dendrite.yaml 中的数据库连接字符串
    if [ -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        # 转义密码中的特殊字符用于 sed
        ESCAPED_PASS=$(echo "$NEW_PGPASS" | sed 's/[&/\]/\\&/g')
        sed -i "s/postgres:\/\/dendrite:.*@postgres\/dendrite/postgres:\/\/dendrite:${ESCAPED_PASS}@postgres\/dendrite/g" "$INSTALL_DIR/config/dendrite.yaml"
        log "更新 dendrite.yaml 数据库连接字符串"
    fi
    
    # 删除旧的 PostgreSQL 数据以确保使用新密码
    if [ -d "$INSTALL_DIR/pgdata" ]; then
        warn "删除旧的 PostgreSQL 数据..."
        rm -rf "$INSTALL_DIR/pgdata"
        mkdir -p "$INSTALL_DIR/pgdata"
    fi
    
    # 重新启动服务
    start_services_fixed
}

start_services_fixed() {
    log "启动服务（使用固定密码）..."
    
    # 先只启动 PostgreSQL
    info "启动 PostgreSQL..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d postgres
    
    # 等待 PostgreSQL 完全启动
    info "等待 PostgreSQL 初始化..."
    local attempt=1
    while [[ $attempt -le 30 ]]; do
        if docker compose -f "$DOCKER_COMPOSE_FILE" ps postgres | grep -q "Up" && \
           docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
            log "PostgreSQL 已就绪"
            break
        fi
        warn "等待 PostgreSQL... ($attempt/30)"
        sleep 5
        ((attempt++))
    done
    
    if [[ $attempt -gt 30 ]]; then
        error "PostgreSQL 启动失败"
        docker compose -f "$DOCKER_COMPOSE_FILE" logs postgres
        return 1
    fi
    
    # 给 PostgreSQL 更多时间初始化数据库
    info "等待数据库初始化完成..."
    sleep 10
    
    # 测试数据库连接
    info "测试数据库连接..."
    if docker exec dendrite_postgres psql -U dendrite -d dendrite -c "SELECT 1;" >/dev/null 2>&1; then
        log "数据库连接测试成功"
    else
        error "数据库连接测试失败"
        return 1
    fi
    
    # 现在启动其他服务
    info "启动其他服务..."
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    
    # 等待服务启动
    info "等待服务启动..."
    sleep 20
    
    # 检查服务状态
    check_services_status
}

check_services_status() {
    log "检查服务状态..."
    
    echo
    echo "=== 服务状态 ==="
    docker compose -f "$DOCKER_COMPOSE_FILE" ps
    
    echo
    echo "=== 最近日志 ==="
    docker compose -f "$DOCKER_COMPOSE_FILE" logs --tail=10
    
    # 检查 Dendrite 是否在运行
    if docker compose -f "$DOCKER_COMPOSE_FILE" ps dendrite | grep -q "Up"; then
        log "Dendrite 服务正在运行"
        return 0
    else
        warn "Dendrite 服务可能有问题，检查日志..."
        docker compose -f "$DOCKER_COMPOSE_FILE" logs dendrite --tail=20
        return 1
    fi
}

create_admin_user_fixed() {
    log "创建管理员账户..."
    
    # 等待 Dendrite 完全启动
    info "等待 Dendrite 启动..."
    local attempt=1
    while [[ $attempt -le 20 ]]; do
        if docker exec dendrite_server curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log "Dendrite 已就绪，开始创建管理员账户"
            break
        fi
        warn "等待 Dendrite 启动... ($attempt/20)"
        sleep 10
        ((attempt++))
    done
    
    if [[ $attempt -gt 20 ]]; then
        warn "Dendrite 启动较慢，尝试创建管理员账户..."
    fi
    
    # 生成管理员密码
    ADMIN_USER="admin"
    ADMIN_PASS=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)
    
    info "管理员账号: $ADMIN_USER"
    info "管理员密码: $ADMIN_PASS"
    
    # 创建管理员账户
    local create_attempt=1
    while [[ $create_attempt -le 5 ]]; do
        if docker exec dendrite_server /usr/bin/create-account \
            -config /etc/dendrite/dendrite.yaml \
            -username "$ADMIN_USER" \
            -password "$ADMIN_PASS" \
            -admin; then
            log "管理员账户创建成功"
            return 0
        fi
        warn "创建管理员账户失败，重试... ($create_attempt/5)"
        sleep 10
        ((create_attempt++))
    done
    
    warn "管理员账户创建失败，请稍后手动创建"
    return 1
}

# -------------------------------
# 完整修复安装
# -------------------------------
complete_fix_installation() {
    log "开始完整修复安装..."
    
    # 获取服务器地址
    SERVER_NAME="38.47.238.148"
    info "使用地址: $SERVER_NAME"
    
    # 清理现有容器
    log "清理现有容器..."
    docker compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true
    docker rm -f dendrite_server dendrite_postgres element_web caddy_proxy 2>/dev/null || true
    
    # 确保目录存在
    mkdir -p "$INSTALL_DIR"/{config,pgdata,logs} "$WEB_DIR" "$CADDY_DIR"/{data,config} "$BACKUP_DIR"
    
    # 生成新密码
    PGPASS=$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    info "数据库密码: $PGPASS"
    
    # 重新生成所有配置文件
    regenerate_configs || return 1
    
    # 使用修复的启动流程
    fix_password_issue || return 1
    
    # 创建管理员账户
    create_admin_user_fixed || warn "管理员账户创建可能需要手动完成"
    
    show_final_success_message
}

regenerate_configs() {
    log "重新生成配置文件..."
    
    # 生成 docker-compose.yml
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:15-alpine
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: "${PGPASS}"
      POSTGRES_DB: dendrite
    volumes:
      - $INSTALL_DIR/pgdata:/var/lib/postgresql/data
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
      - $INSTALL_DIR/config:/etc/dendrite
    environment:
      - DENDRITE_CONFIG=/etc/dendrite/dendrite.yaml

  element-web:
    image: vectorim/element-web:latest
    container_name: element_web
    restart: unless-stopped
    volumes:
      - $WEB_DIR/config.json:/app/config.json

  caddy:
    image: caddy:2-alpine
    container_name: caddy_proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile
      - $CADDY_DIR/data:/data
      - $CADDY_DIR/config:/config
EOF

    # 生成 Caddyfile
    cat > "$CADDY_DIR/Caddyfile" <<EOF
${SERVER_NAME} {
    tls internal
    
    reverse_proxy /_matrix/* dendrite:8008
    reverse_proxy /_matrix/federation/* dendrite:8448
    reverse_proxy /* element-web:80
}
EOF

    # 生成 Element Web 配置
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

    # 生成 Dendrite 密钥
    log "生成 Dendrite 密钥..."
    if [ ! -f "$INSTALL_DIR/config/matrix_key.pem" ]; then
        docker run --rm --entrypoint="/usr/bin/generate-keys" \
            -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
            -private-key /mnt/matrix_key.pem \
            -tls-cert /mnt/server.crt \
            -tls-key /mnt/server.key
    fi

    # 生成 Dendrite 配置
    log "生成 Dendrite 配置..."
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
    
    log "配置文件生成完成"
}

show_final_success_message() {
    echo
    echo "======================================"
    echo "修复完成！"
    echo "======================================"
    echo "访问地址: https://${SERVER_NAME}"
    echo
    echo "如果仍有问题，请检查："
    echo "1. 服务状态: docker compose -f $DOCKER_COMPOSE_FILE ps"
    echo "2. Dendrite 日志: docker compose -f $DOCKER_COMPOSE_FILE logs dendrite"
    echo "3. PostgreSQL 日志: docker compose -f $DOCKER_COMPOSE_FILE logs postgres"
    echo
    echo "要创建管理员账户，请运行:"
    echo "docker exec dendrite_server /usr/bin/create-account -config /etc/dendrite/dendrite.yaml -username admin -password YOUR_PASSWORD -admin"
    echo "======================================"
}

# -------------------------------
# 诊断函数
# -------------------------------
diagnose_current_issue() {
    log "诊断当前问题..."
    
    echo
    echo "=== 当前容器状态 ==="
    docker ps -a | grep -E "(dendrite|postgres|element|caddy)" || echo "没有相关容器"
    
    echo
    echo "=== 检查配置文件 ==="
    if [ -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        echo "Dendrite 配置存在"
        grep "connection_string" "$INSTALL_DIR/config/dendrite.yaml" | head -1
    else
        echo "Dendrite 配置不存在"
    fi
    
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        echo "Docker Compose 文件存在"
        grep "POSTGRES_PASSWORD" "$DOCKER_COMPOSE_FILE" || echo "未找到密码配置"
    else
        echo "Docker Compose 文件不存在"
    fi
    
    echo
    echo "=== 检查数据库 ==="
    if docker ps | grep -q "dendrite_postgres"; then
        echo "PostgreSQL 容器正在运行"
        # 尝试连接数据库
        if docker exec dendrite_postgres psql -U dendrite -d dendrite -c "SELECT 1;" 2>/dev/null; then
            echo "数据库连接成功"
        else
            echo "数据库连接失败"
        fi
    else
        echo "PostgreSQL 容器未运行"
    fi
}

# -------------------------------
# 手动修复函数
# -------------------------------
manual_fix_password() {
    log "手动修复密码..."
    
    if [ ! -f "$DOCKER_COMPOSE_FILE" ] || [ ! -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        error "配置文件不存在，请先运行完整修复"
        return 1
    fi
    
    # 获取当前 docker-compose 中的密码
    CURRENT_PASS=$(grep "POSTGRES_PASSWORD" "$DOCKER_COMPOSE_FILE" | cut -d: -f2 | tr -d ' \"')
    info "当前 Docker Compose 密码: $CURRENT_PASS"
    
    # 获取 dendrite.yaml 中的密码
    DB_URL=$(grep "connection_string" "$INSTALL_DIR/config/dendrite.yaml" | head -1 | awk '{print $2}')
    if [[ "$DB_URL" =~ postgres://dendrite:([^@]+)@ ]]; then
        CONFIG_PASS="${BASH_REMATCH[1]}"
        info "当前配置文件中密码: $CONFIG_PASS"
    else
        error "无法从配置文件中提取密码"
        return 1
    fi
    
    if [ "$CURRENT_PASS" != "$CONFIG_PASS" ]; then
        warn "密码不匹配，进行修复..."
        # 更新配置文件中的密码
        sed -i "s|postgres://dendrite:${CONFIG_PASS}@postgres/dendrite|postgres://dendrite:${CURRENT_PASS}@postgres/dendrite|g" "$INSTALL_DIR/config/dendrite.yaml"
        log "已同步密码"
    else
        log "密码已同步，无需修复"
    fi
    
    # 重启服务
    log "重启服务..."
    docker compose -f "$DOCKER_COMPOSE_FILE" down
    docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    
    log "手动修复完成"
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 密码修复脚本"
    echo "======================================"
    echo
    echo "请选择操作："
    echo "1) 完整修复安装（推荐）"
    echo "2) 仅修复密码问题"
    echo "3) 手动修复密码同步"
    echo "4) 诊断当前问题"
    echo "5) 查看服务状态"
    echo "6) 查看服务日志"
    echo "7) 清理并重新开始"
    echo "0) 退出"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) complete_fix_installation ;;
        2) fix_password_issue ;;
        3) manual_fix_password ;;
        4) diagnose_current_issue ;;
        5) 
            echo "=== 服务状态 ==="
            docker compose -f "$DOCKER_COMPOSE_FILE" ps 2>/dev/null || echo "Docker Compose 文件不存在"
            ;;
        6)
            echo "选择要查看的日志："
            echo "1) Dendrite"
            echo "2) PostgreSQL"
            echo "3) Caddy"
            echo "4) 所有服务"
            read -p "请输入数字: " log_choice
            case "$log_choice" in
                1) docker compose -f "$DOCKER_COMPOSE_FILE" logs dendrite 2>/dev/null || echo "无法查看日志" ;;
                2) docker compose -f "$DOCKER_COMPOSE_FILE" logs postgres 2>/dev/null || echo "无法查看日志" ;;
                3) docker compose -f "$DOCKER_COMPOSE_FILE" logs caddy 2>/dev/null || echo "无法查看日志" ;;
                4) docker compose -f "$DOCKER_COMPOSE_FILE" logs 2>/dev/null || echo "无法查看日志" ;;
            esac
            ;;
        7)
            if confirm "确定要清理所有数据并重新开始吗？"; then
                log "清理所有数据..."
                docker compose -f "$DOCKER_COMPOSE_FILE" down -v 2>/dev/null || true
                rm -rf "$INSTALL_DIR" "$WEB_DIR" "$CADDY_DIR" "$DOCKER_COMPOSE_FILE"
                log "清理完成"
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

log "密码修复脚本开始执行"
main_menu
