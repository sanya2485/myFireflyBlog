#!/usr/bin/env bash
# release-activate.sh <slot> — 把 current 原子翻转到目标槽，自检失败自动回滚。
#
# 用法: release-activate.sh slot-a | slot-b
#
# 流程: flock 互斥 → 槽完整性门(index.html + .deploy.json) → nginx -t 预检 →
#       幂等(已在目标槽则 exit 0) → 原子换链(ln -s 临时名 + mv -Tf) → nginx -s reload →
#       curl 首页 200 + probe 200 自检 → 失败自动翻回 prev 槽并 reload → exit 1。
#
# 关键坑(写死在注释里):
#   * current 必须是"相对"软链 releases/<slot>——容器内是 /usr/share/nginx/html，
#     绝对链 /root/cc/... 在容器内解析不了。
#   * 换链必须 mv -Tf(把临时链 rename 覆盖到 current)；普通 `mv` 会把临时链"移进"目标目录。
#   * .deploy.json 是完整性门：CI 的 SCP 带 rm:true 会清空槽内文件，marker 必须 SCP 之后才写。
#   * 自检 curl https://127.0.0.1 无 Host 头 → 命中默认 443 server(=www 主块) → 200。
set -euo pipefail

BASE=${BLOG_BASE:-/root/cc/blog}
CT=myFireflyBlog
SLOT=${1:-}

[ -n "$SLOT" ] || { echo "usage: $0 slot-a|slot-b"; exit 2; }
case "$SLOT" in slot-a|slot-b) ;; *) echo "bad slot: $SLOT"; exit 2 ;; esac

# ---- 互斥：整个 翻转+reload+smoke+回滚 期间持锁；拿不到立即退出(CI 即红，人工稍候重试)
LOCK="$BASE/.release.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "busy: another activate/release holds the lock"; exit 3; }

# ---- 槽完整性门
[ -f "$BASE/releases/$SLOT/index.html" ]     || { echo "incomplete: no index.html in $SLOT"; exit 4; }
[ -f "$BASE/releases/$SLOT/.deploy.json" ]   || { echo "incomplete: no .deploy.json in $SLOT (marker must be written AFTER scp)"; exit 4; }

# ---- nginx 配置语法预检（在运行容器内；conf 含 coze-net 上游，容器内解析正常）
docker exec "$CT" nginx -t >/dev/null 2>&1 || { echo "nginx conf invalid"; exit 5; }

# ---- 幂等
PREV=$(readlink "$BASE/current" 2>/dev/null || true); PREV=${PREV#releases/}
case "$PREV" in slot-a|slot-b) ;; *) PREV="" ;; esac
if [ "$PREV" = "$SLOT" ]; then echo "already active on $SLOT"; exit 0; fi

flip() {
  ln -s "releases/$1" "$BASE/.cur.$$"
  mv -Tf "$BASE/.cur.$$" "$BASE/current"
}

smoke() {
  local code code2 probe
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 https://127.0.0.1/ 2>/dev/null || echo 000)
  [ "$code" = "200" ] || return 1
  probe=$(sed -n 's/.*"probe":"\([^"]*\)".*/\1/p' "$BASE/releases/$SLOT/.deploy.json" 2>/dev/null || true)
  if [ -n "$probe" ]; then
    code2=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://127.0.0.1$probe" 2>/dev/null || echo 000)
    [ "$code2" = "200" ] || return 1
  fi
  return 0
}

flip "$SLOT"
docker exec "$CT" nginx -s reload >/dev/null 2>&1 || true

if smoke; then
  echo "activated $SLOT (prev=${PREV:-none})"
  exit 0
fi

echo "SMOKE FAILED on $SLOT → auto rollback to ${PREV:-previous}"
if [ -n "$PREV" ] && [ -d "$BASE/releases/$PREV" ]; then
  flip "$PREV"
  docker exec "$CT" nginx -s reload >/dev/null 2>&1 || true
fi
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 https://127.0.0.1/ 2>/dev/null || echo 000)
echo "after rollback home=$code"
exit 1
