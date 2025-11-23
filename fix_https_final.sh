#!/bin/bash
set -e

echo "彻底修复 HTTPS 问题..."

# 停止服务
docker compose -f /opt/docker-compose.yml down

# 完全清理 Caddy 数据
rm -rf /opt/caddy/data/* /opt/caddy/config/*
mkdir -p /opt/caddy/{data,config}

# 创建简化的 Caddyfile
cat > /opt/caddy/Caddyfile <<'EOF'
{
    # 禁用自动 TLS 管理，使用内部证书
    auto_https disable_redirects
}

# HTTP 重定向到 HTTPS（可选）
http://38.47.238.148 {
    redir https://38.47.238.148{uri} permanent
}

# HTTPS 站点配置
https://38.47.238.148 {
    # 使用内部生成的 TLS 证书
    tls internal
    
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

# 重新启动服务
docker compose -f /opt/docker-compose.yml up -d

echo "等待服务启动..."
sleep 10

echo "检查 Caddy 状态..."
docker logs caddy_proxy --tail=20

echo "测试连接..."
echo "HTTP 测试:"
curl -s -o /dev/null -w "HTTP 状态码: %{http_code}\n" http://38.47.238.148 || echo "HTTP 失败"

echo "HTTPS 测试:"
curl -k -s -o /dev/null -w "HTTPS 状态码: %{http_code}\n" https://38.47.238.148 || echo "HTTPS 失败"
