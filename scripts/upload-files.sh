#!/usr/bin/env bash
# ============================================
# myFireflyBlog — 上传随文附件到服务器 /files/ 目录
# ============================================
# 用途: 博客文章随文附件不随 git 部署（避免拖慢 SCP 全量上传），
#       由本脚本直接 scp 到服务器 /root/cc/files/，nginx 挂载为 /files/ 提供下载。
#
# 失败处理: 自动重试（默认 3 次，间隔 5s），多次失败后报错并给出人工介入指引。
#
# 用法:
#   ./scripts/upload-files.sh <本地文件或目录> [<slug>]
# 示例:
#   ./scripts/upload-files.sh public/files/my-post-demo/sample.zip my-post-demo
#   → 服务器: /root/cc/files/my-post-demo/sample.zip
#   → 文章引用: [下载说明](/files/my-post-demo/sample.zip)
#
# 配置 (.env.local，已被 gitignore；也可用环境变量覆盖):
#   BLOG_SERVER_HOST         服务器 IP/域名（必填）
#   BLOG_SERVER_USER         登录用户（默认 root）
#   BLOG_SSH_KEY             SSH 私钥路径（默认使用 ~/.ssh 默认密钥）
#   BLOG_FILES_REMOTE_DIR    服务器目标目录（默认 /root/cc/files）
#   BLOG_URL                 博客线上地址（默认 https://www.sanyablog.cn，仅用于打印链接）
#   BLOG_UPLOAD_MAX_RETRY    失败重试次数（默认 3）
#   BLOG_UPLOAD_RETRY_DELAY  重试间隔秒数（默认 5）
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 加载 .env.local（若存在）
if [ -f "${REPO_DIR}/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_DIR}/.env.local"
  set +a
fi

SRC="${1:-}"
SLUG="${2:-}"

: "${BLOG_SERVER_USER:=root}"
: "${BLOG_FILES_REMOTE_DIR:=/root/cc/files}"
: "${BLOG_URL:=https://www.sanyablog.cn}"
: "${BLOG_UPLOAD_MAX_RETRY:=3}"
: "${BLOG_UPLOAD_RETRY_DELAY:=5}"

if [ -z "${SRC}" ]; then
  echo "用法: $0 <本地文件或目录> [<slug>]" >&2
  exit 1
fi
if [ -z "${BLOG_SERVER_HOST:-}" ]; then
  echo "❌ 缺少 BLOG_SERVER_HOST。请复制 .env.local.example 为 .env.local 并填写服务器 IP/域名。" >&2
  exit 1
fi
if [ ! -e "${SRC}" ]; then
  echo "❌ 本地路径不存在: ${SRC}" >&2
  exit 1
fi

REMOTE_TARGET="${BLOG_FILES_REMOTE_DIR}"
if [ -n "${SLUG}" ]; then
  REMOTE_TARGET="${REMOTE_TARGET}/${SLUG}"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "${BLOG_SSH_KEY:-}" ]; then
  SSH_OPTS+=(-i "${BLOG_SSH_KEY}" -o IdentitiesOnly=yes)
fi

HOST="${BLOG_SERVER_USER}@${BLOG_SERVER_HOST}"
BASE="$(basename "${SRC}")"

# ---------- 上传（带失败重试） ----------
last_err=""
attempt=0
while [ "${attempt}" -lt "${BLOG_UPLOAD_MAX_RETRY}" ]; do
  attempt=$((attempt + 1))
  echo "📤 上传（第 ${attempt}/${BLOG_UPLOAD_MAX_RETRY} 次尝试）: ${SRC}"
  echo "  → ${HOST}:${REMOTE_TARGET}/"

  last_err=""
  if ! ssh "${SSH_OPTS[@]}" "${HOST}" "mkdir -p '${REMOTE_TARGET}'"; then
    last_err="SSH 连接或创建远程目录失败"
  elif ! scp "${SSH_OPTS[@]}" -r "${SRC}" "${HOST}:${REMOTE_TARGET}/"; then
    last_err="SCP 上传失败"
  fi

  if [ -z "${last_err}" ]; then
    if [ -n "${SLUG}" ]; then
      URL_PATH="/files/${SLUG}/${BASE}"
    else
      URL_PATH="/files/${BASE}"
    fi
    echo "✅ 上传成功（第 ${attempt} 次尝试）"
    echo "   线上路径: ${BLOG_URL}${URL_PATH}"
    exit 0
  fi

  echo "⚠️ 第 ${attempt} 次失败（${last_err}）"
  if [ "${attempt}" -lt "${BLOG_UPLOAD_MAX_RETRY}" ]; then
    echo "   ${BLOG_UPLOAD_RETRY_DELAY}s 后重试..."
    sleep "${BLOG_UPLOAD_RETRY_DELAY}"
  fi
done

# ---------- 兜底：多次失败，提醒用户人工介入 ----------
if [ -n "${BLOG_SSH_KEY:-}" ]; then
  MANUAL_SCP="scp -i '${BLOG_SSH_KEY}' -r '${SRC}' ${HOST}:'${REMOTE_TARGET}/'"
else
  MANUAL_SCP="scp -r '${SRC}' ${HOST}:'${REMOTE_TARGET}/'"
fi

echo ""
echo "❌ 上传失败 ${BLOG_UPLOAD_MAX_RETRY} 次（最后一次错误：${last_err}）。需要人工介入。" >&2
echo "" >&2
echo "  排查步骤：" >&2
echo "    1) 检查连通性:     ssh ${HOST} 'echo ok'" >&2
echo "    2) 检查磁盘空间:   ssh ${HOST} 'df -h ${BLOG_FILES_REMOTE_DIR}'" >&2
echo "    3) 手动上传:       ${MANUAL_SCP}" >&2
echo "    4) 修正后重跑:     $0 '${SRC}'${SLUG:+ '${SLUG}'}" >&2
exit 1
