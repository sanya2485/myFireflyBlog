#!/usr/bin/env bash
# 快速回退：自建壳 AgentChat → Coze Web SDK 聊天窗（单 agent，无 /对暗号 Dify 解锁）
#
# 前提：当前仓库用的是 AgentChat 自建壳（M3）。本脚本把 CozeChat.astro 换回
#       tag coze-sdk-shell 的旧 SDK 版本，删除 AgentChat.svelte，提交并推送触发 CI/CD。
# 自建壳代码不会丢，已存于 tag: agentchat-self-shell。
# 恢复：bash scripts/restore-agentchat-shell.sh
# 用法：bash scripts/rollback-coze-sdk.sh
set -euo pipefail
cd "$(dirname "$0")/.." # 仓库根

# 安全闸：工作区有未提交的已跟踪改动时拒绝执行（未跟踪文件如 .playwright-cli 不影响）
if git status --porcelain | grep -qE '^[^?]'; then
  echo "工作区有未提交的已跟踪改动，先提交或 git stash 再执行。" >&2
  exit 1
fi

echo "==> 从 tag coze-sdk-shell 恢复旧版 Coze SDK 聊天窗 CozeChat.astro ..."
git checkout coze-sdk-shell -- src/components/widget/CozeChat.astro

echo "==> 移除自建壳 AgentChat.svelte ..."
git rm -q src/components/widget/AgentChat.svelte

echo "==> 类型检查（失败则中止并恢复现场）..."
if ! pnpm check; then
  echo "astro check 失败，已中止回退，恢复现场。" >&2
  git checkout HEAD -- src/components/widget/CozeChat.astro src/components/widget/AgentChat.svelte
  exit 1
fi

echo "==> 提交并推送（触发 CI/CD 自动部署）..."
git commit -q -m "revert: 回退到 Coze Web SDK 聊天窗（自建壳存档于 tag agentchat-self-shell）"
git push origin master

echo "回退完成。CI/CD 部署后即为 SDK 聊天窗。要恢复自建壳：bash scripts/restore-agentchat-shell.sh"
