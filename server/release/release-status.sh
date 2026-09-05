#!/usr/bin/env bash
# release-status.sh — 只读查看蓝绿状态：current 指向、两槽指纹（index mtime / 文件数 / commit）。
set -euo pipefail

BASE=${BLOG_BASE:-/root/cc/blog}

cur=$(readlink "$BASE/current" 2>/dev/null || true)
echo "current=${cur:-<none>}"
echo "resolved=$(readlink -f "$BASE/current" 2>/dev/null || echo broken)"

for s in slot-a slot-b; do
  idx="$BASE/releases/$s/index.html"
  if [ -f "$idx" ]; then
    m=$(stat -c %Y "$idx" 2>/dev/null || echo 0)
    commit=$(sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' "$BASE/releases/$s/.deploy.json" 2>/dev/null || true)
    n=$(find "$BASE/releases/$s" -type f ! -name '.deploy.json' 2>/dev/null | wc -l)
    printf '%s: index_mtime=%s files=%s commit=%s\n' "$s" "$m" "$n" "${commit:-none}"
  else
    printf '%s: INVALID (no index.html)\n' "$s"
  fi
done
