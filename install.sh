#!/bin/bash
set -e

echo "======================================"
echo "   Dendrite Matrix 服务器一键安装脚本"
echo "======================================"

# 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo "安装 Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
fi

# 检查 Docker Compose 是否安装
if ! command -v docker-compose &> /dev/null; then
    echo "安装 Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# 创建安装目录
echo "创建安装目录..."
sudo mkdir -p /opt/dendrite-simple
cd /opt/dendrite-simple
sudo mkdir -p config data/media_store logs

# 获取服务器IP
SERVER_IP=$(curl -s ifconfig.me)
echo "检测到服务器IP: $SERVER_IP"

# 创建 Docker Compose 文件
echo "创建 Docker Compose 配置..."
sudo tee docker-compose.yml > /dev/null <<'DOCKEREOF'
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
    image: matrixdotorg/dendrite-monolith:latest
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
    restart: unless-stopped
DOCKEREOF

# 生成私钥
echo "生成私钥..."
sudo openssl genrsa -out config/matrix_key.pem 2048
sudo chmod 644 config/matrix_key.pem

# 创建配置文件
echo "创建配置文件..."
sudo tee config/dendrite.yaml > /dev/null <<CONFIGEOF
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
CONFIGEOF

# 启动服务
echo "启动 Dendrite 服务..."
sudo docker-compose up -d

echo "等待服务启动（30秒）..."
for i in {1..30}; do
    echo -n "."
    sleep 1
done
echo ""

# 检查服务状态
echo "检查服务状态..."
if sudo docker-compose ps | grep -q "Up"; then
    echo "✅ 服务启动成功"
else
    echo "❌ 服务启动失败，请检查日志"
    sudo docker-compose logs dendrite
    exit 1
fi

# 创建管理员账户
echo "创建管理员账户..."
sudo docker-compose exec dendrite /usr/bin/create-account \
    --config /etc/dendrite/dendrite.yaml \
    --username admin \
    --password admin123 \
    --admin

echo ""
echo "======================================"
echo "       安装完成！"
echo "======================================"
echo "访问地址: http://$SERVER_IP:8008"
echo "管理员账号: admin"
echo "管理员密码: admin123"
echo ""
echo "管理命令:"
echo "查看状态: cd /opt/dendrite-simple && sudo docker-compose ps"
echo "查看日志: cd /opt/dendrite-simple && sudo docker-compose logs -f dendrite"
echo "重启服务: cd /opt/dendrite-simple && sudo docker-compose restart"
echo "停止服务: cd /opt/dendrite-simple && sudo docker-compose down"
echo "======================================"

# 测试服务
echo "测试服务连通性..."
if curl -s http://localhost:8008/_matrix/client/versions > /dev/null; then
    echo "✅ 服务测试成功"
else
    echo "⚠️  服务测试失败，但安装已完成。请稍后重试。"
fi
