---
title: 一次阿里云 ECS 异地登录误报排查与顺手加固
published: 2026-07-15
description: 凌晨收到阿里云异地登录告警，美国 IP 成功 SSH 登录 8 次——虚惊一场的背后是一次完整的安全排查与加固
tags: [安全, Linux, SSH, 运维, 阿里云]
category: 运维实践
draft: false
---

## 凌晨的告警

某天凌晨，阿里云发来异地登录告警：来自 **美国弗吉尼亚** 的 IP 以 root 身份 SSH 登录了 **8 次**。

第一反应：密钥泄露了。

## 排查过程

### 登录日志分析

```bash
# 追踪特定 IP
grep 'xx.xx.xx.xx' /var/log/secure

# 爆破统计
grep 'Failed password' /var/log/secure | \
  awk '{print $(NF-3)}' | sort | uniq -c | sort -rn

# 最近登录记录
last -20
```

### 发现模式重复

为了验证，手动触发了一次 CI/CD 部署，服务器再次出现完全相同的连接模式：

| 对比项 | 第一次（被报警） | 手动触发 |
|--------|-----------------|---------|
| 连接 IP | 美国 Azure | 美国 Azure |
| 连接次数 | 8 次 | 8 次 |
| 连接模式 | 22 秒内多端口并发 | 22 秒内多端口并发 |
| 部署结果 | - | 成功 ✅ |

**模式完全一致**——原来是 GitHub Actions 的 runner 跑在 Azure 基础设施上，SCP 上传时建立多个 SSH 并发连接（分片传输），被阿里云异地登录检测误报了。

### 顺手发现真实攻击

在同一份日志中发现了来自另一个 IP 的 **287 次 SSH 密码爆破尝试**，持续 14 分钟，全部失败。

```bash
# 封禁爆破 IP
iptables -A INPUT -s xx.xx.xx.xx -j DROP
```

## 安全加固清单

趁这个机会完成了一次完整的安全加固：

| 措施 | 说明 |
|------|------|
| 关闭 SSH 密码登录 | `PasswordAuthentication no`，只允许密钥登录 |
| 安装 fail2ban | 5 次失败自动封禁 24 小时 |
| 更换 SSH 密钥 | 旧密钥作废，更换新密钥对 |
| 更新 CI/CD Secrets | 替换为新私钥 |
| 封禁爆破 IP | iptables DROP |
| 解封 CI/CD IP | 确认为 GitHub Actions，从黑名单移除 |

### 后门排查

确认是误报后，还是彻底检查了一遍系统：

- 当前运行进程 → 无异常
- systemd 服务 → 无新增服务
- crontab / 定时任务 → 无后门
- 系统用户 → 只有必要的系统用户
- `authorized_keys` → 清理到只剩 2 个必要密钥
- Docker 容器 → 无异常
- 系统文件完整性（`rpm -Va`）→ 无篡改
- 监听端口 → 仅 22(SSH) + 80(nginx)
- `/tmp`、`/dev/shm` → 无可疑文件

## 总结

虚惊一场——所谓的"攻击"是 GitHub Actions CI/CD 的正常 SCP 上传行为，因 runner 位于美国 Azure 区域被阿里云异地登录检测误报。但借着这次误报完成了一次系统安全加固，也算是有惊无险的收获。

**建议**：如果你也用 GitHub Actions 部署到国内云服务器，收到异地登录告警时先确认是不是 CI runner 的连接，别急着封 IP。
