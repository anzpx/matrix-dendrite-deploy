#!/bin/bash
set -e

CADDY_DIR="/opt/caddy"
DOCKER_COMPOSE_FILE="/opt/docker-compose.yml"

echo "修复 SSL 连接问题..."

# 停止服务
docker compose -f "$DOCKER_COMPOSE_FILE" down

# 清理 Caddy 数据
rm -rf "$CADDY_DIR/data" "$CADDY_DIR/config"
mkdir -p "$CADDY_DIR"/{data,config}

# 重新生成简化的 Caddyfile
cat > "$CADDY_DIR/Caddyfile" <<'EOF'
{
    auto_https off
}

http://38.47.238.148 {
    reverse_proxy /_matrix/* dendrite:8008
    reverse_proxy /_matrix/federation/* dendrite:8448
    reverse_proxy /* element-web:80
}

https://38.47.238.148 {
    tls internal
    reverse_proxy /_matrix/* dendrite:8008
    reverse_proxy /_matrix/federation/* dendrite:8448
    reverse_proxy /* element-web:80
}
EOF

# 重新启动服务
docker compose -f "$DOCKER_COMPOSE_FILE" up -d

echo "修复完成，等待服务启动..."
sleep 10

# 测试服务
echo "测试 HTTP 访问..."
curl -s -o /dev/null -w "%{http_code}" http://38.47.238.148 || echo "HTTP 访问失败"

echo "测试 HTTPS 访问..."
curl -k -s -o /dev/null -w "%{http_code}" https://38.47.238.148 || echo "HTTPS 访问失败"

echo "检查服务状态:"
docker compose -f "$DOCKER_COMPOSE_FILE" ps
