# Matrix Dendrite 自动部署

## 功能
- 一键部署 Dendrite + PostgreSQL + Nginx
- 公网自动申请 Let’s Encrypt 证书
- 内网自动生成自签名证书
- Docker Compose 部署，无需手动安装数据库
- 交互式输入参数（域名/IP、数据库密码、管理员账号）

## 快速部署

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/anzpx/matrix-dendrite-deploy/main/install_dendrite_interactive.sh)"
```

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/anzpx/matrix-dendrite-deploy/main/install.sh)"
```

执行后会依次提示输入：
1. 域名或 VPS IP
2. PostgreSQL 数据库密码
3. 管理员账号用户名
4. 管理员密码（隐藏输入）

脚本会自动判断证书类型。

## 日志
- `/opt/dendrite/logs/install.log` 安装日志
- `/opt/dendrite/logs/nginx_access.log` 访问日志
- `/opt/dendrite/logs/nginx_error.log` 错误日志

