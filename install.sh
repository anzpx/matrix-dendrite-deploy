#!/usr/bin/env bash
set -euo pipefail
# 一键部署 Matrix Dendrite (Docker) + Postgres + Nginx + HTTPS
# 适用于 Ubuntu 22.04
# 特性：
# - 安装 Docker / docker-compose (compose plugin)
# - 生成 docker-compose.yml (dendrite monolith + postgres)
# - 自动生成 dendrite.yaml 和 matrix_key.pem
# - 创建 Postgres DB & user
# - 启动服务
# - 配置 Nginx 反代（80/443 -> dendrite），若输入为域名则尝试使用 Certbot 获取 Let's Encrypt 证书，
#   若为裸 IP 则自动创建自签名证书并配置 nginx 使用
# - 使用 dendrite 自带 create-account 工具创建管理员账号（用户名 admin，可自定义）
#
# 使用：
# $ sudo bash install_dendrite.sh
#
# 默认目录：/opt/dendrite-deploy
#
# 运行前请确认端口 80、443 没有被占用（脚本会尝试停止占用者 nginx）
#
########################
# 配置区（默认值，可在运行时交互修改）
########################
BASE_DIR="/opt/dendrite-deploy"
COMPOSE_PROJECT_NAME="dendrite"
DENDRITE_IMAGE="matrixdotorg/dendrite-monolith:latest"
POSTGRES_IMAGE="postgres:15"
# 下面是你提供的管理员地址／域名／IP（已由用户指定）
SERVER_NAME="38.47.238.148"
# 管理员账号 (可改)
ADMIN_USER="admin"
# 如果你希望脚本自动生成管理员密码则置空，脚本会随机生成
ADMIN_PASS=""

# 数据库密码（若留空会随机生成）
DB_PASSWORD=""
# dendrite 配置中的 registration_shared_secret，用于 create-account 工具（脚本会生成）
REG_SHARED_SECRET=""

########################
# End 配置区
########################

info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# helper
is_ip(){
  # 判断是否为 IPv4
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

random_secret(){
  head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32
}

ensure_sudo(){
  if [ "$EUID" -ne 0 ]; then
    warn "脚本需要 root 权限，请使用 sudo 运行（或切换到 root）。"
    exit 1
  fi
}

ensure_sudo

# 交互：允许用户覆盖配置
read -p "安装目录（默认 ${BASE_DIR}）： " tmp && [ -n "$tmp" ] && BASE_DIR="$tmp"
read -p "Dendrite 镜像（默认 ${DENDRITE_IMAGE}）： " tmp && [ -n "$tmp" ] && DENDRITE_IMAGE="$tmp"
read -p "Postgres 镜像（默认 ${POSTGRES_IMAGE}）： " tmp && [ -n "$tmp" ] && POSTGRES_IMAGE="$tmp"
read -p "服务器域名/IP（默认 ${SERVER_NAME}）： " tmp && [ -n "$tmp" ] && SERVER_NAME="$tmp"
read -p "管理员用户名（默认 ${ADMIN_USER}）： " tmp && [ -n "$tmp" ] && ADMIN_USER="$tmp"
read -p "若要自定义管理员密码请输入（留空则随机生成）： " tmp && ADMIN_PASS="$tmp"
read -p "若要自定义 Postgres 密码请输（留空则随机生成）： " tmp && DB_PASSWORD="$tmp"

# 生成随机密码/密钥（如未提供）
[ -z "$DB_PASSWORD" ] && DB_PASSWORD="$(random_secret)"
[ -z "$ADMIN_PASS" ] && ADMIN_PASS="$(random_secret)"
[ -z "$REG_SHARED_SECRET" ] && REG_SHARED_SECRET="$(random_secret)"

info "使用配置："
echo "  BASE_DIR = $BASE_DIR"
echo "  SERVER_NAME = $SERVER_NAME"
echo "  ADMIN_USER = $ADMIN_USER"
echo "  (admin pass 已生成或使用你输入的值)"
echo "  Postgres password 已生成或使用你输入的值"

# 安装依赖：docker, docker-compose-plugin, nginx, certbot (仅在需要时)
install_prereqs(){
  info "更新 apt 并安装依赖..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common apt-transport-https
  # Docker 官方源
  if ! command -v docker >/dev/null 2>&1; then
    info "安装 Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io
  else
    info "检测到已安装 docker"
  fi

  # docker compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    info "安装 docker compose 插件..."
    DOCKER_PLUGIN_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(dpkg --print-architecture)"
    curl -L "$DOCKER_PLUGIN_URL" -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  else
    info "检测到 docker compose 已安装"
  fi

  # nginx & certbot (certbot 仅用于域名)
  apt-get install -y nginx
  if ! command -v certbot >/dev/null 2>&1; then
    info "安装 certbot..."
    apt-get install -y certbot python3-certbot-nginx || warn "certbot 安装失败或不可用（后续可能使用自签名证书）"
  fi
}

# 创建目录结构
prepare_dirs(){
  info "创建目录 ${BASE_DIR} ..."
  mkdir -p "$BASE_DIR"
  cd "$BASE_DIR"
  mkdir -p data/postgres data/dendrite nginx/etc
}

# 生成 docker-compose.yml
generate_docker_compose(){
  info "生成 docker-compose.yml ..."
  cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.8"
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
      POSTGRES_USER: dendrite
      POSTGRES_DB: dendrite
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - dendrite-net

  dendrite:
    image: ${DENDRITE_IMAGE}
    container_name: dendrite_monolith
    restart: unless-stopped
    volumes:
      - ./data/dendrite:/etc/dendrite
      - ./data/media_store:/var/lib/dendrite/media_store
    depends_on:
      - postgres
    networks:
      - dendrite-net
    # 将 dendrite 的 client_api HTTP 暴露到主机，便于 nginx 反向代理
    ports:
      - "8008:8008"   # client API (HTTP)
      - "8448:8448"   # federation (HTTPS)
networks:
  dendrite-net:
    driver: bridge
EOF
}

# 生成 matrix_key.pem (server signing key)
generate_matrix_key(){
  info "生成 matrix_key.pem ..."
  mkdir -p "$BASE_DIR/data/dendrite"
  if [ ! -f "$BASE_DIR/data/dendrite/matrix_key.pem" ]; then
    openssl genrsa -out "$BASE_DIR/data/dendrite/matrix_key.pem" 2048
    chmod 600 "$BASE_DIR/data/dendrite/matrix_key.pem"
  else
    info "matrix_key.pem 已存在，跳过"
  fi
}

# 生成基本 dendrite.yaml（最小可用）
generate_dendrite_yaml(){
  info "生成 dendrite.yaml ..."
  cat > "$BASE_DIR/data/dendrite/dendrite.yaml" <<EOF
# 自动生成 - 最小示例配置，请按需调整
server_name: "${SERVER_NAME}"
# 文件路径
global:
  key_server:
    # path to generated server key
    key_name: "matrix_key.pem"
  room_server:
    database:
      name: "postgres"
      connection_string: "host=postgres port=5432 user=dendrite dbname=dendrite password=${DB_PASSWORD} sslmode=disable"
  user_api:
    account_database:
      name: "postgres"
      connection_string: "host=postgres port=5432 user=dendrite dbname=dendrite password=${DB_PASSWORD} sslmode=disable"
client_api:
  registration_disabled: true
  registration_shared_secret: "${REG_SHARED_SECRET}"
  bind:
    address: "0.0.0.0"
    port: 8008
federation_api:
  bind:
    address: "0.0.0.0"
    port: 8448
  tls_cert_path: "/etc/dendrite/tls/fullchain.pem"
  tls_key_path: "/etc/dendrite/tls/privkey.pem"
logging:
  level: info
  pretty: true
media_api:
  base_path: "/var/lib/dendrite/media_store"
# 以上为最小示例配置，若需启用更多功能请参考官方文档。
EOF
  chmod 600 "$BASE_DIR/data/dendrite/dendrite.yaml"
}

# Create Postgres DB & user (inside container) — we use environment vars so container auto-creates.
ensure_postgres(){
  info "启动 Postgres 并等待就绪..."
  cd "$BASE_DIR"
  docker compose up -d postgres
  info "等待 Postgres 启动 (最多 60s)..."
  n=0
  until docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1 || [ $n -ge 60 ]; do
    sleep 1; n=$((n+1))
  done
  if docker exec dendrite_postgres pg_isready -U dendrite >/dev/null 2>&1; then
    info "Postgres 就绪"
  else
    err "Postgres 启动超时或失败，请检查容器日志： docker logs dendrite_postgres"
    exit 1
  fi
  # Postgres DB/user 已在容器启动时由环境变量创建 (POSTGRES_USER/POSTGRES_DB/POSTGRES_PASSWORD)
}

# 启动 dendrite 服务（后台）
start_dendrite(){
  info "启动 Dendrite 容器..."
  cd "$BASE_DIR"
  docker compose up -d dendrite
  info "等待 Dendrite 启动 (最多 60s)..."
  n=0
  until docker logs dendrite_monolith 2>&1 | grep -q "Listening for client API on"; do
    sleep 1
    n=$((n+1))
    if [ $n -ge 60 ]; then
      warn "等待 Dendrite 启动超时（60s），请稍后手动检查容器日志： docker logs dendrite_monolith"
      break
    fi
  done
  info "Dendrite 启动命令已触发，请检查容器状态"
}

# 创建管理员账号（使用 container 内的 /bin/create-account）
create_admin(){
  info "创建管理员账号 ${ADMIN_USER} ..."
  # create-account binary 位于镜像内 /bin/create-account
  sleep 1
  # 使用 docker compose exec 调用 create-account
  # 由于 create-account 会尝试连接到 client API (默认 http://localhost:8008)，而我们把端口映射到主机 8008:8008，所以可以在主机上用 http://127.0.0.1:8008
  # 使用 -admin 标记创建管理员
  if docker compose ps | grep -q dendrite; then
    echo -e "${ADMIN_PASS}\n${ADMIN_PASS}" | docker compose exec -T dendrite /bin/create-account -config /etc/dendrite/dendrite.yaml -username "${ADMIN_USER}" -password "-" -admin -url "http://127.0.0.1:8008" || {
      warn "直接使用 create-account 失败，尝试在容器内交互创建..."
      docker compose exec dendrite /bin/create-account -config /etc/dendrite/dendrite.yaml -username "${ADMIN_USER}" -admin -url "http://127.0.0.1:8008"
    }
    info "管理员创建完成：用户名=${ADMIN_USER} 密码=${ADMIN_PASS}"
  else
    err "Dendrite 容器未在运行，无法创建管理员"
  fi
}

# 配置 nginx 反向代理并设置 TLS
configure_nginx_and_tls(){
  info "配置 Nginx 反向代理..."
  # 先备份默认配置并创建新站点
  NGINX_CONF="/etc/nginx/sites-available/dendrite"
  NGINX_LINK="/etc/nginx/sites-enabled/dendrite"
  if [ -f "$NGINX_CONF" ]; then
    info "已存在 ${NGINX_CONF}，备份到 ${NGINX_CONF}.bak"
    cp "$NGINX_CONF" "${NGINX_CONF}.bak"
  fi

  # 当使用 IP 时，Let's Encrypt 无法签发证书 —— 使用自签名证书
  if is_ip "$SERVER_NAME"; then
    warn "检测到 SERVER_NAME 为 IP (${SERVER_NAME})，Let's Encrypt 无法为裸 IP 签发证书。脚本将为你生成自签名证书并配置 Nginx。注意：浏览器会提示不受信任。"
    mkdir -p "$BASE_DIR/data/dendrite/tls"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$BASE_DIR/data/dendrite/tls/privkey.pem" \
      -out "$BASE_DIR/data/dendrite/tls/fullchain.pem" \
      -subj "/C=US/ST=None/L=None/O=Matrix/CN=${SERVER_NAME}"
    chmod 600 "$BASE_DIR/data/dendrite/tls/"*.pem
    CERT_PATH="$BASE_DIR/data/dendrite/tls/fullchain.pem"
    KEY_PATH="$BASE_DIR/data/dendrite/tls/privkey.pem"
    info "自签名证书已生成： ${CERT_PATH}"
    USE_LETSENCRYPT=false
  else
    # 试着用 certbot 获取证书
    USE_LETSENCRYPT=true
  fi

  # 生成 nginx 配置（先 HTTP -> redirect to HTTPS, HTTPS -> proxy）
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};
    # http -> https
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${SERVER_NAME};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ssl_certificate /etc/dendrite/tls/fullchain.pem;
    ssl_certificate_key /etc/dendrite/tls/privkey.pem;

    # client API (HTTP)
    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # 其它流量也转发到客户端 api
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  # 创建 certbot webroot 目录（如果需要）
  mkdir -p /var/www/certbot
  ln -sf "$NGINX_CONF" "$NGINX_LINK"
  nginx -t && systemctl reload nginx

  if [ "$USE_LETSENCRYPT" = true ]; then
    info "尝试使用 Certbot 获取 Let's Encrypt 证书（需要域名已解析并开放 80/443）..."
    if command -v certbot >/dev/null 2>&1; then
      # 使用 webroot 模式获取证书
      certbot certonly --nginx -d "${SERVER_NAME}" --non-interactive --agree-tos -m "admin@${SERVER_NAME}" || {
        warn "Certbot 获取证书失败，改为生成自签名证书。"
        mkdir -p "$BASE_DIR/data/dendrite/tls"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
          -keyout "$BASE_DIR/data/dendrite/tls/privkey.pem" \
          -out "$BASE_DIR/data/dendrite/tls/fullchain.pem" \
          -subj "/C=US/ST=None/L=None/O=Matrix/CN=${SERVER_NAME}"
        chmod 600 "$BASE_DIR/data/dendrite/tls/"*.pem
      }

      # 若 certbot 成功，它会放在 /etc/letsencrypt/live/<domain>/fullchain.pem
      if [ -f "/etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem" ]; then
        info "Certbot 成功获取证书，创建软链到 dendrite 配置目录..."
        mkdir -p "$BASE_DIR/data/dendrite/tls"
        ln -sf "/etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem" "$BASE_DIR/data/dendrite/tls/fullchain.pem"
        ln -sf "/etc/letsencrypt/live/${SERVER_NAME}/privkey.pem" "$BASE_DIR/data/dendrite/tls/privkey.pem"
      fi
    else
      warn "certbot 未安装，无法申请 Let's Encrypt 证书。"
    fi
  fi

  # 把 TLS 文件放到 /etc/dendrite (nginx 读取配置中指定的路径)
  # 我们将把数据目录中的 tls 链接或文件复制到 /etc/dendrite
  mkdir -p /etc/dendrite
  cp -r "$BASE_DIR/data/dendrite/tls/." /etc/dendrite/ || true
  chown root:root /etc/dendrite/*.pem || true
  chmod 600 /etc/dendrite/*.pem || true

  nginx -t && systemctl reload nginx
  info "Nginx 已配置并重载。"
}

# 显示最终信息与访问方式
final_info(){
  echo
  cat <<EOF
============================================================
部署完成（或已尽力完成自动化步骤）。请查看下面信息：
- 数据目录： ${BASE_DIR}/data
- docker-compose 文件： ${BASE_DIR}/docker-compose.yml
- dendrite 配置： ${BASE_DIR}/data/dendrite/dendrite.yaml
- Postgres 用户： dendrite
- Postgres 密码： ${DB_PASSWORD}
- 管理员账号： ${ADMIN_USER}
- 管理员密码： ${ADMIN_PASS}
- server_name: ${SERVER_NAME}

访问方式：
- 客户端 API (HTTP) : http://${SERVER_NAME}:8008
- Federation (HTTPS) : https://${SERVER_NAME}:8448  (注意：如果使用自签名证书，浏览器会提示不受信任)
- Nginx 代理（对外）: https://${SERVER_NAME}/

常用命令：
- 查看容器： docker compose ps
- 查看某容器日志： docker logs dendrite_monolith
- 停止服务： cd ${BASE_DIR} && docker compose down
- 启动服务： cd ${BASE_DIR} && docker compose up -d

若要重新生成配置或调整 dendrite.yaml，请编辑：
  ${BASE_DIR}/data/dendrite/dendrite.yaml
编辑后重启 Dendrite 容器：
  docker compose restart dendrite

官方文档（强烈建议查看）：
- https://matrix-org.github.io/dendrite/

问题排查：
- 若 admin 创建失败，请进入 Dendrite 容器交互运行 create-account：
  docker compose exec -it dendrite /bin/sh
  /bin/create-account -config /etc/dendrite/dendrite.yaml -username ${ADMIN_USER} -admin

============================================================
EOF
}

##### 主流程 #####
install_prereqs
prepare_dirs
generate_docker_compose
generate_matrix_key
generate_dendrite_yaml

info "开始拉取镜像并启动 Postgres + Dendrite (通过 docker compose)..."
cd "$BASE_DIR"
docker compose pull || true
ensure_postgres
start_dendrite

configure_nginx_and_tls

# 最后尝试创建管理员
create_admin

final_info
