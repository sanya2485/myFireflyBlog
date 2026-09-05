#!/usr/bin/env bash
# release-slot-pick.sh — 输出"非活动槽"名（slot-a|slot-b），供 CI 决定把 dist 填进哪个槽。
#
# 读 /root/cc/blog/current 相对软链的末尾段判定活动槽，输出另一个。
# current 异常/不存在时输出 none（CI 应据此报"先跑迁移"而非硬编码清某个槽）。
set -euo pipefail

BASE=${BLOG_BASE:-/root/cc/blog}
cur=$(readlink "$BASE/current" 2>/dev/null || true)

case "$cur" in
  *slot-a) echo slot-b ;;
  *slot-b) echo slot-a ;;
  *) echo none ;;
esac
