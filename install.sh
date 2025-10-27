#!/bin/bash
set -e

# 完全清理
cd /opt/dendrite-simple
sudo docker-compose down
cd /opt
sudo rm -rf dendrite-simple

# 重新创建目录
sudo mkdir -p /opt/dendrite-fixed
cd /opt/dendrite-fixed
sudo mkdir -p config data/media_store logs

# 获取服务器IP
SERVER_IP=$(curl -s ifconfig.me)

# 使用传统格式生成 RSA 私钥
sudo openssl genrsa -traditional -out config/matrix_key.pem 2048
sudo chmod 644 config/matrix_key.pem

# 验证私钥格式
echo "验证私钥格式:"
sudo head -1 config/matrix_key.pem
sudo openssl rsa -in config/matrix_key.pem -check -noout

# 创建 Docker Compose 文件
sudo tee docker-compose.yml > /dev/null <<'EOF'
version: '3.7'
services:
  postgres:
    image: postgres:15
    environment:
      - POSTGRES_USER=dendrite
      - POSTGRES_PASSWORD=dendrite_password
      - POSTGRES_DB=dendrite
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dendrite -d dendrite"]
      interval: 5s
      timeout: 5s
      retries: 10

  dendrite:
    image: matrixdotorg/dendrite-monolith:v0.13.4
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8008:8008"
      - "8448:8448"
    volumes:
      - ./config:/etc/dendrite
      - ./data/media_store:/etc/dendrite/media_store
      - ./logs:/var/log
    command: >
      sh -c "
        # 等待配置文件就绪
        while [ ! -f /etc/dendrite/dendrite.yaml ]; do
          echo '等待配置文件...'
          sleep 2
        done
        
        # 检查私钥文件
        echo '检查私钥文件...'
        ls -la /etc/dendrite/matrix_key.pem
        head -1 /etc/dendrite/matrix_key.pem
        
        # 启动 Dendrite
        echo '启动 Dendrite...'
        /usr/bin/dendrite-monolith --config /etc/dendrite/dendrite.yaml
      "
    restart: unless-stopped
EOF

# 创建配置文件
sudo tee config/dendrite.yaml > /dev/null <<EOF
global:
  server_name: $SERVER_IP
  private_key: /etc/dendrite/matrix_key.pem

database:
  connection_string: postgres://dendrite:dendrite_password@postgres:5432/dendrite?sslmode=disable

client_api:
  registration_shared_secret: "$(openssl rand -hex 32)"
  internal_api:
    connect: http://localhost:7771
    listen: http://0.0.0.0:7771
  external_api:
    listen: http://0.0.0.0:8008

federation_api:
  internal_api:
    connect: http://localhost:7772
    listen: http://0.0.0.0:7772
  external_api:
    listen: http://0.0.0.0:8448

media_api:
  internal_api:
    connect: http://localhost:7775
    listen: http://0.0.0.0:7775
  external_api:
    listen: http://0.0.0.0:8075
  base_path: /etc/dendrite/media_store

sync_api:
  internal_api:
    connect: http://localhost:7773
    listen: http://0.0.0.0:7773

user_api:
  internal_api:
    connect: http://localhost:7781
    listen: http://0.0.0.0:7781
  account_database:
    connection_string: postgres://dendrite:dendrite_password@postgres:5432/dendrite?sslmode=disable

logging:
- type: file
  level: info
  params:
    path: /var/log/dendrite.log
EOF

# 启动服务
sudo docker-compose up -d

echo "等待服务启动..."
sleep 30

# 检查状态和日志
sudo docker-compose ps
sudo docker-compose logs --tail=20 dendrite

# 如果服务正常运行，创建管理员账户
if sudo docker-compose ps | grep dendrite | grep -q "Up"; then
    echo "创建管理员账户..."
    sudo docker-compose exec dendrite /usr/bin/create-account \
        --config /etc/dendrite/dendrite.yaml \
        --username admin \
        --password admin123 \
        --admin
    
    echo "======================================"
    echo "      Dendrite 安装完成！"
    echo "======================================"
    echo "访问地址: http://$SERVER_IP:8008"
    echo "管理员账号: admin" 
    echo "管理员密码: admin123"
else
    echo "❌ Dendrite 服务启动失败，请检查日志"
    sudo docker-compose logs dendrite
fi
