#!/usr/bin/env bash
# ============================================================
# 上传脚本：创建 GitHub 仓库并推送 fnOS 插件包
# 用法: ./upload.sh <GITHUB_TOKEN> [仓库名]
# 默认仓库名: fpkDeepSeekHarness
# ============================================================
set -euo pipefail

TOKEN="${1:-}"
REPO_NAME="${2:-fpkDeepSeekHarness}"
REPO_DESC="飞牛 fnOS DeepSeek Harness 插件包"
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "$TOKEN" ]]; then
  echo "错误: 请提供 GitHub Token，用法: $0 <GITHUB_TOKEN> [仓库名]" >&2
  exit 1
fi

API="https://api.github.com"

# 1. 创建仓库（私有，可改为 public）
echo "==> 创建 GitHub 仓库: $REPO_NAME"
CREATE=$(curl -sS -f -X POST "$API/user/repos" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "{\"name\":\"$REPO_NAME\",\"description\":\"$REPO_DESC\",\"private\":true,\"auto_init\":false}") \
  || { echo "创建仓库失败，可能已存在或 Token 权限不足" >&2; exit 1; }

CLONE_URL=$(echo "$CREATE" | sed -n 's/.*"clone_url": "\([^"]*\)".*/\1/p')
[[ -z "$CLONE_URL" ]] && CLONE_URL="https://github.com/$(echo "$CREATE" | sed -n 's/.*"full_name": "\([^"]*\)".*/\1/p').git"
echo "    仓库地址: $CLONE_URL"

# 2. 检查 fpk 文件
FPK_COUNT=$(find "$WORK_DIR" -maxdepth 1 -iname "*.fpk" | wc -l)
if [[ "$FPK_COUNT" -eq 0 ]]; then
  echo "错误: $WORK_DIR 下没有 .fpk 文件" >&2
  exit 1
fi
echo "==> 发现 $FPK_COUNT 个 fpk 文件"

# 3. 初始化 git 并提交
cd "$WORK_DIR"
if [[ ! -d .git ]]; then
  git init -b main
fi
git config user.name "DeepSeek Harness"
git config user.email "deepseek-harness@users.noreply.github.com"
git add -A
if git diff --cached --quiet; then
  echo "    无变更，跳过提交"
else
  git commit -m "chore: 发布 fnOS 插件包 $(date +%Y-%m-%d)"
fi

# 4. 推送（带 Token）
AUTH_URL="https://x-access-token:${TOKEN}@github.com/$(echo "$CLONE_URL" | sed 's|https://github.com/||')"
git remote remove origin 2>/dev/null || true
git remote add origin "$AUTH_URL"
git branch -M main
git push -u origin main

echo ""
echo "✅ 上传完成！访问: https://github.com/$(echo "$CLONE_URL" | sed 's|https://github.com/||' | sed 's|\.git$||')"
