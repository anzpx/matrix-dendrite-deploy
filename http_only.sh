#!/bin/bash
set -e

echo "切换到 HTTP-only 配置..."

# 停止服务
docker compose -f /opt/docker-compose.yml down

# 创建仅 HTTP 的 Caddyfile
cat > /opt/caddy/Caddyfile <<'EOF'
# 仅使用 HTTP 访问
http://38.47.238.148 {
    # 矩阵客户端 API
    handle /_matrix/client/* {
        reverse_proxy dendrite:8008
    }
    
    # 矩阵联邦 API
    handle /_matrix/federation/* {
        reverse_proxy dendrite:8448
    }
    
    # Element Web 前端
    handle /* {
        reverse_proxy element-web:80
    }
}
EOF

# 更新 docker-compose.yml 只映射 80 端口
cat > /opt/docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:15-alpine
    container_name: dendrite_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: dendrite
      POSTGRES_PASSWORD: "k9Nzbf7VwN5GZb52invHQIparviasfyv"
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
      - "80:80"  # 只映射 80 端口，不映射 443
    volumes:
      - /opt/caddy/Caddyfile:/etc/caddy/Caddyfile
      - /opt/caddy/data:/data
      - /opt/caddy/config:/config
EOF

# 更新 Element Web 配置使用 HTTP
cat > /opt/element-web/config.json <<'EOF'
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://38.47.238.148",
            "server_name": "38.47.238.148"
        }
    },
    "brand": "Element"
}
EOF

# 重启服务
docker compose -f /opt/docker-compose.yml up -d

echo "等待服务启动..."
sleep 10

echo "测试 HTTP 访问..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://38.47.238.148)
echo "HTTP 状态码: $HTTP_STATUS"

if [ "$HTTP_STATUS" = "200" ]; then
    echo "✅ HTTP 服务正常运行！"
    echo ""
    echo "======================================"
    echo "🎉 Matrix Dendrite 安装成功！"
    echo "======================================"
    echo "访问地址: http://38.47.238.148"
    echo "管理员账号: admin"
    echo "管理员密码: lymJ0wpUYay2tUqn"
    echo ""
    echo "重要提示:"
    echo "1. 使用 HTTP 访问（不是 HTTPS）"
    echo "2. 某些 Matrix 客户端可能要求 HTTPS"
    echo "3. 如需 HTTPS，建议使用域名和反向代理"
    echo "======================================"
else
    echo "❌ HTTP 服务仍有问题"
    echo "检查服务状态:"
    docker compose -f /opt/docker-compose.yml ps
    echo "查看 Caddy 日志:"
    docker logs caddy_proxy --tail=10
fi
