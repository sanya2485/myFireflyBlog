---
title: Nginx 配置与项目部署解耦：envsubst + 独立 Workflow
published: 2026-07-15
description: 解决 nginx 配置和博客内容耦合在同一个 CI/CD 流程中的问题，实现各自独立更新
tags: [nginx, GitHub Actions, CI/CD, DevOps, 部署]
category: 技术实践
draft: false
---

## 问题

博客的 nginx 一直跑着官方默认配置——Gzip 没开、安全头没有、缓存策略全无。更麻烦的是，nginx 配置和博客内容耦合在同一个部署流程里：

```
deploy-server.yml: pnpm build → SCP dist/ → docker run
```

想改个缓存时间？得改项目代码、走完整构建、等 CI/CD 跑完。改完容器重启，配置又丢了（无状态容器）。

## 方案：四层解耦

### 1. 模板 + envsubst

仓库是公开的，敏感信息（域名/IP）不能明文存。用 `envsubst` 做模板变量替换：

```nginx
# server/nginx/default.conf.template
server {
    server_name  ${BLOG_DOMAIN};
    # ...
}
```

CI/CD 中替换后上传：

```yaml
- run: envsubst '${BLOG_DOMAIN}' < template > default.conf
```

`envsubst '${BLOG_DOMAIN}'` 精确替换指定变量，nginx 自身的 `$` 变量（如 `$remote_addr`）不受影响。

GitHub Secrets 里存 `BLOG_DOMAIN`，仓库里只有模板，不留明文。

### 2. 独立 Workflow

新增 `.github/workflows/deploy-nginx.yml`，只做一件事：

```
手动触发 → envsubst → SCP default.conf → nginx -t 测试 → nginx -s reload
```

和博客内容部署完全独立：

```
改 nginx 配置 → 编辑模板 → 手动触发 Deploy Nginx Config → 10 秒生效
改博客内容 → git push → Deploy to Server 自动触发 → 3 分钟
```

### 3. 条件挂载

博客部署时检测配置文件是否存在：

```bash
CONFIG_MOUNT=""
if [ -f /path/to/conf/default.conf ]; then
  CONFIG_MOUNT="-v /path/to/conf/default.conf:/etc/nginx/conf.d/default.conf:ro"
fi

docker run -d --name myFireflyBlog \
  -v /path/to/dist:/usr/share/nginx/html:ro \
  $CONFIG_MOUNT \
  -p 80:80 --restart always nginx:alpine
```

配置存在则挂载，不存在则退化到默认配置——**零耦合故障点**。

### 4. 配置与内容目录分离

服务器上配置文件和静态文件分开放：

```
/path/to/blog/
├── dist/           # 博客静态文件（SCP 上传）
├── conf/
│   └── default.conf  # nginx 配置（独立 workflow 管理）
```

两个目录互不覆盖，内容 deploy 不会丢配置，配置更新不影响内容。

## 结果

| 操作 | 之前 | 之后 |
|------|------|------|
| 改缓存策略 | 改代码 → push → 等 3 分钟构建 | 改模板 → 触发 workflow → 10 秒 reload |
| 改博客内容 | 同上流程 | git push → 自动部署（不影响配置） |
| 回滚配置 | 无解 | git revert → 触发 workflow |
| 服务器重建 | 手配 nginx | 跑 workflow 一键恢复 |

最直接的收益：**改 nginx 配置从"半小时的项目发布"变成了"10 秒的运维操作"**。
