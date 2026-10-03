#!/bin/bash
# ============================================================
#  测试使用环境变量绕过 pnpm store 权限问题
#  用途：不修改文件系统，通过环境变量指定可写 store 位置
#  用法：bash scripts/test-pnpm-fix-with-env.sh [--install]
# ============================================================

set -u

# 使用 /tmp 作为临时目录（根用户可写）
TEMP_HOME="/tmp/dsh-pnpm-home"
TEMP_STORE="/tmp/pnpm-store"
TEMP_CACHE="/tmp/pnpm-cache"

# 创建必要目录
mkdir -p "$TEMP_HOME" "$TEMP_STORE" "$TEMP_CACHE"

# 写入 .npmrc
cat > "$TEMP_HOME/.npmrc" << 'NPMRC'
# pnpm store 配置（临时修复 - 2026-09-16）
store.path=/tmp/pnpm-store
NPMRC

echo "临时环境已设置:"
echo "  HOME=$TEMP_HOME"
echo "  PNPM_STORE=$TEMP_STORE"
echo "  配置文件: $TEMP_HOME/.npmrc"
echo ""

# 测试 pnpm 命令
echo "测试 pnpm store path..."
if HOME="$TEMP_HOME" node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path 2>&1; then
    echo "✓ pnpm store 路径配置成功"
else
    echo "✗ pnpm store 路径配置失败"
fi

echo ""
echo "下一步：使用以下命令安装插件"
echo ""
echo "  HOME=$TEMP_HOME \\"
echo "  node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs \\"
echo "    add dsh-edit-diff"
echo ""
echo "或者使用 DSH CLI:"
echo ""
echo "  HOME=$TEMP_HOME \\"
echo "  /vol2/1000/DeepSeek\\ Harness/dsh-v0.1.2-alpha.4/.dsh-home/工作区/DeepSeekHarness-NAS/build/master-build/build-0.1.5/target/bin/dsh \\"
echo "    plugin --profile web add dsh-edit-diff"
