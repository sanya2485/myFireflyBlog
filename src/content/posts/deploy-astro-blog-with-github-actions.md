---
title: 使用 GitHub Actions + Docker 自动化部署 Astro 静态博客
published: 2026-07-15
description: 从手动 SCP 上传到一键 CI/CD 部署，记录 myFireflyBlog 的自动化部署方案演进
tags: [Astro, Docker, GitHub Actions, CI/CD, 部署, nginx]
category: 技术实践
draft: false
---

## 动机

项目使用 Astro 构建生成 `dist/` 静态文件，之前一直是手动执行 `pnpm build` → SCP 上传 → SSH 重启容器。每次更新都要重复这套流程，效率低且容易出错。

## 方案设计

采用 **GitHub Actions + Docker + nginx** 的自动化部署方案：

```
Git Push → GitHub Actions (构建) → SCP → Server (nginx:alpine)
```

### 为什么不用 docker-compose？

生产环境只有一个 nginx 容器，没有后端 API、数据库或其他服务，单容器的场景上 docker-compose 是过度工程。

### 为什么构建不在服务器上做？

构建在 GitHub Actions 的 CI runner 上完成，服务器只做文件宿主 + 运行时启动。服务器不需要装 pnpm、Node.js，也不需要跑构建，攻击面更小、运维更轻。

## 工作流设计

`.github/workflows/deploy-server.yml`：

```yaml
触发条件：push 到 master 分支
步骤：
  1. Checkout 代码
  2. Setup Node.js 22 + pnpm
  3. pnpm install --frozen-lockfile
  4. pnpm build
  5. SCP 上传 dist/ 到服务器
  6. SSH 执行 docker run nginx:alpine
```

### Secrets 配置

| Secret | 用途 |
|--------|------|
| `SERVER_HOST` | 服务器 IP |
| `SERVER_USERNAME` | SSH 用户名 |
| `SERVER_SSH_KEY` | SSH 私钥 |
| `BLOG_DOMAIN` | 博客域名或 IP（nginx 模板用） |

## 容器运行

服务器上直接跑 `nginx:alpine` 官方镜像，通过 `-v` 挂载静态文件目录：

```bash
docker run -d --name myFireflyBlog \
  -v /path/to/blog:/usr/share/nginx/html:ro \
  -p 80:80 --restart always nginx:alpine
```

## Nginx 配置

通过独立的 `deploy-nginx.yml` workflow 管理，与博客内容部署解耦：

### Gzip 压缩

```nginx
gzip on;
gzip_types text/plain text/css application/json application/javascript image/svg+xml;
gzip_vary on;
```

### 安全头

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

### 缓存策略（针对 Astro 构建产物）

```nginx
# 内容哈希文件名 —— 不可变缓存
location /_astro/   { expires 365d; add_header Cache-Control "public, immutable"; }

# 通用静态资源
location /assets/   { expires 30d;  add_header Cache-Control "public"; }

# 搜索索引
location /pagefind/ { expires 7d;   add_header Cache-Control "public"; }

# HTML 页面不缓存（内容更新需即时生效）
location ~* \.html$ { expires -1;   add_header Cache-Control "no-cache"; }
```

## 一些经验

### 条件挂载避免耦合

nginx 配置通过独立 workflow 管理，博客内容 deploy 时检测配置是否存在：

```bash
CONFIG_MOUNT=""
if [ -f /path/to/conf/default.conf ]; then
  CONFIG_MOUNT="-v /path/to/conf/default.conf:/etc/nginx/conf.d/default.conf:ro"
fi

docker run -d \
  --name myFireflyBlog \
  -v /path/to/dist:/usr/share/nginx/html:ro \
  $CONFIG_MOUNT \
  -p 80:80 --restart always nginx:alpine
```

配置存在则挂载，不存在则退化到默认配置，两个 workflow 独立但不耦合。

### 安全加固顺手做

在配置部署的过程中顺带加固了 SSH 安全：
- 关闭密码登录（`PasswordAuthentication no`）
- 安装 fail2ban 防爆破
- 更换密钥对

## 总结

这套方案跑下来最满意的一点是**变更域分离**——博客内容和服务器配置走不同的 workflow，各自独立更新互不影响。改配置不需要重新构建，发文章不需要碰服务器配置。

对比之前的纯手动流程，现在每天更新博客的心理负担降到了零：写完 `git push` 等三分钟就好了。
