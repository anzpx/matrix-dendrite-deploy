#!/bin/bash
set -e

# -------------------------------
# 配置变量
# -------------------------------
INSTALL_DIR="/opt/dendrite"
DOCKER_COMPOSE_FILE="/opt/docker-compose.yml"

# -------------------------------
# 颜色输出函数
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

error() {
    echo -e "${RED}[错误]${NC} $1"
}

info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

# -------------------------------
# 修复共享密钥问题
# -------------------------------
fix_shared_secret() {
    log "修复共享密钥配置..."
    
    # 生成共享密钥
    SHARED_SECRET=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)
    info "生成的共享密钥: $SHARED_SECRET"
    
    # 检查配置文件是否存在
    if [ ! -f "$INSTALL_DIR/config/dendrite.yaml" ]; then
        error "Dendrite 配置文件不存在: $INSTALL_DIR/config/dendrite.yaml"
        return 1
    fi
    
    # 备份原配置
    cp "$INSTALL_DIR/config/dendrite.yaml" "$INSTALL_DIR/config/dendrite.yaml.backup"
    
    # 添加共享密钥配置
    if grep -q "registration_shared_secret" "$INSTALL_DIR/config/dendrite.yaml"; then
        # 如果已存在，则更新
        sed -i "s/registration_shared_secret:.*/registration_shared_secret: \"$SHARED_SECRET\"/" "$INSTALL_DIR/config/dendrite.yaml"
        log "已更新共享密钥"
    else
        # 如果不存在，则添加
        # 找到 client_api 部分并插入
        if grep -q "client_api:" "$INSTALL_DIR/config/dendrite.yaml"; then
            # 在 client_api: 下面插入
            sed -i "/client_api:/a\ \ registration_shared_secret: \"$SHARED_SECRET\"" "$INSTALL_DIR/config/dendrite.yaml"
        else
            # 如果 client_api 不存在，在文件末尾添加
            echo "client_api:" >> "$INSTALL_DIR/config/dendrite.yaml"
            echo "  registration_shared_secret: \"$SHARED_SECRET\"" >> "$INSTALL_DIR/config/dendrite.yaml"
        fi
        log "已添加共享密钥配置"
    fi
    
    # 重启 Dendrite 服务以应用配置
    log "重启 Dendrite 服务..."
    docker compose -f "$DOCKER_COMPOSE_FILE" restart dendrite
    
    # 等待服务重新启动
    info "等待 Dendrite 重启..."
    sleep 10
}

create_admin_account() {
    log "创建管理员账户..."
    
    # 生成管理员密码
    ADMIN_USER="admin"
    ADMIN_PASS=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)
    
    info "管理员账号: $ADMIN_USER"
    info "管理员密码: $ADMIN_PASS"
    info "请妥善保存这些信息！"
    
    # 等待 Dendrite 完全启动
    local attempt=1
    while [[ $attempt -le 10 ]]; do
        if docker exec dendrite_server curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log "Dendrite 已就绪，开始创建管理员账户"
            break
        fi
        warn "等待 Dendrite 启动... ($attempt/10)"
        sleep 5
        ((attempt++))
    done
    
    # 创建管理员账户
    if docker exec dendrite_server /usr/bin/create-account \
        -config /etc/dendrite/dendrite.yaml \
        -username "$ADMIN_USER" \
        -password "$ADMIN_PASS" \
        -admin; then
        log "✅ 管理员账户创建成功！"
        echo
        echo "======================================"
        echo "管理员账户信息："
        echo "用户名: $ADMIN_USER"
        echo "密码: $ADMIN_PASS"
        echo "======================================"
    else
        error "管理员账户创建失败"
        return 1
    fi
}

# -------------------------------
# 测试服务访问
# -------------------------------
test_service_access() {
    log "测试服务访问..."
    
    SERVER_NAME="38.47.238.148"
    
    echo
    echo "=== 服务访问测试 ==="
    
    # 测试 Element Web
    info "测试 Element Web..."
    if curl -s -k "https://$SERVER_NAME" | grep -q "Element"; then
        log "✅ Element Web 可访问"
    else
        warn "⚠ Element Web 访问可能有问题"
    fi
    
    # 测试 Dendrite Client API
    info "测试 Dendrite Client API..."
    if curl -s -k "https://$SERVER_NAME/_matrix/client/versions" | grep -q "versions"; then
        log "✅ Dendrite Client API 可访问"
    else
        warn "⚠ Dendrite Client API 访问可能有问题"
    fi
    
    # 测试 Dendrite Federation API
    info "测试 Dendrite Federation API..."
    if curl -s -k "https://$SERVER_NAME/_matrix/federation/v1/version" | grep -q "server"; then
        log "✅ Dendrite Federation API 可访问"
    else
        warn "⚠ Dendrite Federation API 访问可能有问题"
    fi
    
    echo
    info "访问地址: https://$SERVER_NAME"
}

# -------------------------------
# 显示完整状态
# -------------------------------
show_complete_status() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 安装完成状态"
    echo "======================================"
    
    echo
    echo "=== 服务状态 ==="
    docker compose -f "$DOCKER_COMPOSE_FILE" ps
    
    echo
    echo "=== 网络配置 ==="
    docker network ls | grep opt_default
    
    echo
    echo "=== 最近日志 ==="
    docker compose -f "$DOCKER_COMPOSE_FILE" logs --tail=5
    
    echo
    echo "======================================"
}

# -------------------------------
# 主菜单
# -------------------------------
main_menu() {
    echo
    echo "======================================"
    echo " Matrix Dendrite 最终配置脚本"
    echo "======================================"
    echo
    echo "请选择操作："
    echo "1) 修复共享密钥并创建管理员账户"
    echo "2) 仅创建管理员账户（已修复共享密钥）"
    echo "3) 测试服务访问"
    echo "4) 显示完整状态"
    echo "5) 查看服务日志"
    echo "0) 退出"
    echo
    read -p "请输入数字: " OPTION

    case "$OPTION" in
        1) 
            fix_shared_secret
            sleep 5
            create_admin_account
            test_service_access
            ;;
        2) 
            create_admin_account
            test_service_access
            ;;
        3) 
            test_service_access
            ;;
        4) 
            show_complete_status
            ;;
        5)
            echo "选择要查看的日志："
            echo "1) Dendrite"
            echo "2) PostgreSQL" 
            echo "3) Caddy"
            echo "4) Element Web"
            echo "5) 所有服务"
            read -p "请输入数字: " log_choice
            case "$log_choice" in
                1) docker compose -f "$DOCKER_COMPOSE_FILE" logs dendrite ;;
                2) docker compose -f "$DOCKER_COMPOSE_FILE" logs postgres ;;
                3) docker compose -f "$DOCKER_COMPOSE_FILE" logs caddy ;;
                4) docker compose -f "$DOCKER_COMPOSE_FILE" logs element-web ;;
                5) docker compose -f "$DOCKER_COMPOSE_FILE" logs ;;
            esac
            ;;
        0) 
            echo "退出脚本"
            exit 0
            ;;
        *) 
            error "无效选项"
            ;;
    esac
}

# 脚本入口
main_menu
