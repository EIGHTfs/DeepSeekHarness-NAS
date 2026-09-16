#!/bin/bash
# 测试 pnpm store 写入能力
set -u

STORE="/vol2/1000/DeepSeek Harness/.pnpm-store/v11"

echo "=== 测试 pnpm store 写入 ==="
echo ""

# 测试 index.db 写入
echo "1. 测试 index.db 写入..."
if touch "$STORE/index.db" 2>&1; then
    echo "   ✓ index.db 可写"
    rm -f "$STORE/index.db.touch_test"
else
    echo "   ✗ index.db 不可写"
    echo "   错误: $?"
fi

# 测试 files 目录写入
echo ""
echo "2. 测试 files 目录写入..."
TEST_DIR="$STORE/files/test-$$"
if mkdir -p "$TEST_DIR" 2>&1; then
    echo "   ✓ files 目录可创建"
    rmdir "$TEST_DIR"
else
    echo "   ✗ files 目录不可创建"
    echo "   错误: $?"
fi

# 测试 pnpm 命令
echo ""
echo "3. 测试 pnpm store path..."
node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path 2>&1

echo ""
echo "=== 诊断完成 ==="
