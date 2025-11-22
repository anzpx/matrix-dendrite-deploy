#!/bin/bash
set -e

echo "============================="
echo "  一键清理 & 安装 Docker "
echo "============================="

# 1. 停止 Docker 服务
echo "停止旧 Docker 服务..."
sudo systemctl stop docker || true
sudo systemctl stop containerd || true

# 2. 卸载旧版本 Docker
echo "卸载旧版本 Docker..."
sudo apt remove -y docker docker.io docker-engine containerd containerd.io runc || true
sudo apt purge -y docker docker.io docker-engine containerd containerd.io runc || true
sudo apt autoremove -y

# 3. 删除残留文件
echo "删除残留 Docker 数据..."
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker

# 4. 更新系统
echo "更新系统软件包..."
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release software-properties-common

# 5. 添加 Docker 官方源
echo "添加 Docker 官方 GPG key 和源..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 6. 安装 Docker
echo "安装 Docker Engine 和 Docker Compose..."
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 7. 启动 Docker 服务
echo "启用并启动 Docker 服务..."
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl start docker

# 8. 验证安装
echo "============================="
echo "Docker 版本:"
docker --version
echo "Docker Compose 版本:"
docker compose version
echo "============================="

# 9. 测试 Docker
echo "测试 Docker 是否能正常运行 hello-world..."
sudo docker run --rm hello-world

echo "Docker 安装完成，可以正常运行容器！"
