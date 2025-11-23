#!/bin/bash
set -e

INSTALL_DIR="/opt/dendrite"
WEB_DIR="/opt/element-web"
CADDY_DIR="/opt/caddy"
BACKUP_DIR="$INSTALL_DIR/backups"
DOCKER_COMPOSE_FILE="/opt/docker-compose.yml"

echo "======================================"
echo " Matrix Dendrite 一键部署脚本"
echo "======================================"

# -------------------------------
# 菜单选择
# -------------------------------
echo "请选择操作："
echo "1) 安装/部署 Matrix Dendrite"
echo "2) 卸载（删除所有数据）"
echo "3) 升级 Matrix Dendrite + Element-Web + Caddy"
echo "4) 备份数据库"
echo "5) 卸载（保留数据卷和配置）"
echo "0) 退出"
read -p "请输入数字: " OPTION

confirm() {
    read -p "$1 (y/n): " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) echo "操作已取消"; return 1 ;;
    esac
}

case "$OPTION" in
1)
    echo "开始安装/部署..."
    # 自动获取公网 IP
    PUBLIC_IP=$(curl -fsS ifconfig.me || hostname -I | awk '{print $1}')
    if [ -z "$PUBLIC_IP" ]; then
        read -p "无法获取公网 IP，请手动输入服务器公网 IP 或域名: " PUBLIC_IP
    fi

    read -p "请输入域名（回车使用自动获取 IP ${PUBLIC_IP}）: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$PUBLIC_IP}
    echo "使用域名/IP: $SERVER_NAME"

    mkdir -p $INSTALL_DIR/config $INSTALL_DIR/pgdata $WEB_DIR $CADDY_DIR $BACKUP_DIR

    # 安装 Docker & Docker Compose
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    fi

    if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
        curl -L "https://github.com/docker/compose/releases/download/v2.27.2/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    ADMIN_USER="admin"
    ADMIN_PASS=$(head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)
    PGPASS=$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"

    # 生成 docker-compose.yml
    cat > $DOCKER_COMPOSE_FILE <<EOF
version: "3.8"
services:
  postgres:
    container_name: dendrite_postgres
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: "${PGPASS}"
      POSTGRES_DB: dendrite
    volumes:
      - $INSTALL_DIR/pgdata:/var/lib/postgresql/data

  dendrite:
    image: matrixdotorg/dendrite-monolith:latest
    restart: unless-stopped
    depends_on:
      - postgres
    volumes:
      - $INSTALL_DIR/config:/etc/dendrite

  element-web:
    image: vectorim/element-web
    restart: unless-stopped
    volumes:
      - $WEB_DIR/config.json:/app/config.json

  caddy:
    image: caddy:2.7
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
    if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        TLS_MODE="internal"
    else
        TLS_MODE="acme"
    fi

    cat > $CADDY_DIR/Caddyfile <<EOF
${SERVER_NAME} {
    encode gzip
    tls ${TLS_MODE}

    @element path /
    reverse_proxy @element element-web:80

    handle_path /_matrix/* {
        reverse_proxy dendrite:8008
    }

    handle_path /_matrix/federation/* {
        reverse_proxy dendrite:8448
    }
}
EOF

    # Element-Web 配置
    cat > $WEB_DIR/config.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${SERVER_NAME}",
      "server_name": "${SERVER_NAME}"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "brand": "MyMatrixChat",
  "default_theme": "dark"
}
EOF

    # 生成 TLS 私钥和证书
    rm -f $INSTALL_DIR/config/matrix_key.pem $INSTALL_DIR/config/server.crt $INSTALL_DIR/config/server.key
    docker run --rm --entrypoint="/usr/bin/generate-keys" \
      -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
      -private-key /mnt/matrix_key.pem \
      -tls-cert /mnt/server.crt \
      -tls-key /mnt/server.key

    # 生成 dendrite.yaml
    docker run --rm --entrypoint="/usr/bin/generate-config" \
      -v "$INSTALL_DIR/config":/mnt matrixdotorg/dendrite-monolith:latest \
      -dir /var/dendrite \
      -db "postgres://dendrite:${PGPASS}@postgres/dendrite?sslmode=disable" \
      -server "${SERVER_NAME}" \
      > "$INSTALL_DIR/config/dendrite.yaml"
    sed -i 's#/var/dendrite#/etc/dendrite#g' "$INSTALL_DIR/config/dendrite.yaml"

    # 启动服务
    docker compose -f $DOCKER_COMPOSE_FILE up -d

    echo "======================================"
    echo "安装/部署完成"
    echo "访问 Element Web: https://${SERVER_NAME}"
    echo "管理员账号: $ADMIN_USER"
    echo "管理员密码: $ADMIN_PASS"
    echo "查看日志: docker compose -f $DOCKER_COMPOSE_FILE logs -f"
    echo "======================================"
    ;;

2)
    if confirm "确定要卸载并删除所有数据吗？"; then
        echo "开始卸载 Matrix Dendrite（删除所有数据）..."
        docker compose -f $DOCKER_COMPOSE_FILE down || true
        docker compose -f $DOCKER_COMPOSE_FILE rm -f || true
        rm -rf $INSTALL_DIR $WEB_DIR $CADDY_DIR $DOCKER_COMPOSE_FILE
        echo "卸载完成"
    fi
    ;;

3)
    echo "开始升级服务..."
    docker compose -f $DOCKER_COMPOSE_FILE down || true
    docker pull matrixdotorg/dendrite-monolith:latest
    docker pull vectorim/element-web
    docker pull caddy:2.7
    docker compose -f $DOCKER_COMPOSE_FILE up -d
    echo "升级完成"
    ;;

4)
    echo "开始备份数据库..."
    mkdir -p $BACKUP_DIR
    DATE=$(date +'%Y%m%d_%H%M')
    docker exec -t dendrite_postgres pg_dumpall -U dendrite > $BACKUP_DIR/dendrite_$DATE.sql
    echo "备份完成，文件位于 $BACKUP_DIR/dendrite_$DATE.sql"
    ;;

5)
    if confirm "确定要卸载但保留数据卷和配置吗？"; then
        echo "开始卸载 Matrix Dendrite（保留数据卷和配置）..."
        docker compose -f $DOCKER_COMPOSE_FILE down || true
        docker compose -f $DOCKER_COMPOSE_FILE rm -f || true
        rm -f $DOCKER_COMPOSE_FILE
        rm -rf $WEB_DIR $CADDY_DIR
        echo "卸载完成，数据卷和配置已保留"
    fi
    ;;

0)
    echo "退出脚本"
    exit 0
    ;;

*)
    echo "无效选项"
    exit 1
    ;;
esac
