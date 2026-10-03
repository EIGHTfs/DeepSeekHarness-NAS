#!/bin/bash
# ============================================================
#  沙盒限制绕过测试脚本
#  用途：诊断并尝试绕过 DSH 沙盒对 pnpm store 的写入限制
#  用法：bash scripts/test-sandbox-fix.sh
# ============================================================

set -u

STORE="/vol2/1000/DeepSeek Harness/.pnpm-store/v11"
WORKSPACE="/vol2/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4/.dsh-home/工作区/DeepSeekHarness-NAS"

echo "=== DSH 沙盒限制诊断 ==="
echo ""
echo "当前用户: $(whoami) (uid=$(id -u))"
echo "pnpm store: $STORE"
echo "工作区: $WORKSPACE"
echo ""

# 1. 测试不同路径的写入能力
echo "=== 1. 写入能力测试 ==="
echo ""

TEST_PATHS=(
    "$STORE"
    "/vol2/1000/DeepSeek Harness"
    "/vol2/1000"
    "$WORKSPACE"
    "/tmp"
    "$HOME"
)

for path in "${TEST_PATHS[@]}"; do
    if [ -d "$path" ]; then
        TEST_FILE="$path/.write_test_$$"
        if touch "$TEST_FILE" 2>/dev/null; then
            echo "✓ $path - 可写"
            rm -f "$TEST_FILE"
        else
            echo "✗ $path - 只读/权限不足"
        fi
    else
        echo "- $path - 不存在"
    fi
done

# 2. 检查文件系统挂载
echo ""
echo "=== 2. 文件系统挂载信息 ==="
echo ""
mount | grep -E "vol2|DeepSeek" | head -10

# 3. 测试 pnpm 命令
echo ""
echo "=== 3. pnpm 命令测试 ==="
echo ""

# 尝试使用不同 HOME 目录
echo "测试 1: 默认 HOME..."
node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path 2>&1 | head -5

echo ""
echo "测试 2: 使用 /tmp 作为 HOME..."
TEMP_HOME="/tmp/dsh-test-home"
mkdir -p "$TEMP_HOME"
echo "store.path=/tmp/pnpm-store-test" > "$TEMP_HOME/.npmrc"
HOME="$TEMP_HOME" node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path 2>&1

# 4. 解决方案建议
echo ""
echo "=== 4. 解决方案建议 ==="
echo ""
echo "方案 A: 修改 DSH 沙盒配置"
echo "  允许写入 /vol2/1000/DeepSeek Harness/.pnpm-store/"
echo "  位置: DSH 配置文件或启动参数"
echo ""
echo "方案 B: 使用替代 pnpm store 路径"
echo "  1. 创建临时 store:"
echo "     mkdir -p /tmp/pnpm-store"
echo "  2. 配置 .npmrc:"
echo "     echo 'store.path=/tmp/pnpm-store' > ~/.npmrc"
echo "  3. 运行安装命令"
echo ""
echo "方案 C: 使用 workspace-write 沙盒模式"
echo "  确保 DSH 以 workspace-write 模式运行"
echo "  这样允许写入工作区内的所有文件"
echo ""
echo "方案 D: 手动复制 index.db"
echo "  1. 备份原始 index.db"
echo "  2. 复制到 /tmp"
echo "  3. 配置 pnpm 使用复制的数据库"
echo "  4. 安装完成后替换回去"
echo ""

echo "=== 诊断完成 ==="
