#!/usr/bin/env bash
# 恢复自建壳：Coze Web SDK 聊天窗 → AgentChat 自建壳（双 agent + /对暗号 Dify 解锁）
#
# 与 scripts/rollback-coze-sdk.sh 相反，从 tag agentchat-self-shell 恢复自建壳。
# 用法：bash scripts/restore-agentchat-shell.sh
set -euo pipefail
cd "$(dirname "$0")/.." # 仓库根

# 安全闸：工作区有未提交的已跟踪改动时拒绝执行
if git status --porcelain | grep -qE '^[^?]'; then
  echo "工作区有未提交的已跟踪改动，先提交或 git stash 再执行。" >&2
  exit 1
fi

echo "==> 从 tag agentchat-self-shell 恢复自建壳（AgentChat.svelte + CozeChat.astro）..."
git checkout agentchat-self-shell -- \
  src/components/widget/AgentChat.svelte \
  src/components/widget/CozeChat.astro

echo "==> 类型检查（失败则中止并恢复现场）..."
if ! pnpm check; then
  echo "astro check 失败，已中止恢复，恢复现场。" >&2
  git checkout HEAD -- src/components/widget/AgentChat.svelte src/components/widget/CozeChat.astro
  exit 1
fi

echo "==> 提交并推送（触发 CI/CD 自动部署）..."
git commit -q -m "feat: 恢复 AgentChat 自建壳（双 agent + /对暗号，源自 tag agentchat-self-shell）"
git push origin master

echo "恢复完成。CI/CD 部署后即为自建壳。"
