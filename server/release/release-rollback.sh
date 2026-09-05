#!/usr/bin/env bash
# release-rollback.sh — 一键切到"非当前"槽（= 秒级回滚到上一个内容版本）。
# 复用 release-activate.sh 的完整性门/nginx -t/自检/自动回滚逻辑。
set -euo pipefail

BASE=${BLOG_BASE:-/root/cc/blog}
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cur=$(readlink "$BASE/current" 2>/dev/null || true)
case "$cur" in
  *slot-a) target=slot-b ;;
  *slot-b) target=slot-a ;;
  *) echo "cannot determine current slot (readlink='${cur:-<none>}')"; exit 2 ;;
esac

echo "rolling current -> $target"
exec bash "$SELF/release-activate.sh" "$target"
