#!/bin/bash
set -e

echo "切换到 Nginx 配置..."

# 停止并移除现有服务
docker compose -f /opt/docker-compose.yml down

# 安装 Nginx（如果尚未安装）
if ! command -v nginx &>/dev/null; then
    echo "安装 Nginx..."
    apt update && apt install -y nginx
fi

# 创建 Nginx 配置目录
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

# 生成自签名 SSL 证书
echo "生成 SSL 证书..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx.key \
    -out /etc/nginx/ssl/nginx.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=38.47.238.148"

# 创建 Nginx 配置文件
cat > /etc/nginx/sites-available/matrix <<'EOF'
# Matrix Dendrite 服务器配置
server {
    listen 80;
    server_name 38.47.238.148;
    
    # HTTP 重定向到 HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name 38.47.238.148;

    # SSL 配置
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # 安全头
    add_header Strict-Transport-Security "max-age=63072000" always;

    # Client-Server API
    location /_matrix/client {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Matrix 特定配置
        proxy_read_timeout 60s;
        client_max_body_size 50M;
    }

    # Federation API
    location /_matrix/federation {
        proxy_pass http://127.0.0.1:8448;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Matrix 联邦配置
        proxy_read_timeout 60s;
        client_max_body_size 50M;
    }

    # Element Web
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 启用站点
ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# 测试 Nginx 配置
nginx -t

# 更新 docker-compose.yml 移除 Caddy，添加端口映射
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
    ports:
      - "127.0.0.1:8008:8008"  # Client-Server API
      - "127.0.0.1:8448:8448"  # Federation API

  element-web:
    image: vectorim/element-web:latest
    container_name: element_web
    restart: unless-stopped
    volumes:
      - /opt/element-web/config.json:/app/config.json
    ports:
      - "127.0.0.1:8080:80"  # Element Web 界面
EOF

# 更新 Element Web 配置使用 HTTPS
cat > /opt/element-web/config.json <<'EOF'
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://38.47.238.148",
            "server_name": "38.47.238.148"
        }
    },
    "brand": "Element"
}
EOF

# 重启 Docker 服务
docker compose -f /opt/docker-compose.yml up -d

# 重启 Nginx
systemctl enable nginx
systemctl restart nginx

echo "等待服务启动..."
sleep 10

echo "测试服务..."
echo "HTTPS 测试:"
curl -k -s -o /dev/null -w "HTTPS 状态码: %{http_code}\n" https://38.47.238.148 || echo "HTTPS 失败"

echo "检查服务状态:"
docker compose -f /opt/docker-compose.yml ps

echo "Nginx 状态:"
systemctl status nginx --no-pager -l

echo "======================================"
echo "🎉 Nginx 配置完成！"
echo "======================================"
echo "访问地址: https://38.47.238.148"
echo "管理员账号: admin"
echo "管理员密码: lymJ0wpUYay2tUqn"
echo ""
echo "注意: 由于使用自签名证书，浏览器会显示不安全警告"
echo "在手机上访问时，需要点击'高级'->'继续访问'"
echo "======================================"
