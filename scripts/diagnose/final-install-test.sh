#!/bin/bash
# 最终安装测试 - 使用临时 pnpm store
set -u

PLUGIN="dsh-edit-diff"
TEMP_STORE="/tmp/pnpm-store-final"
TEMP_HOME="/tmp/dsh-home-final"

# 创建目录
mkdir -p "$TEMP_STORE" "$TEMP_HOME"

# 写入配置
cat > "$TEMP_HOME/.npmrc" << NPMRC
# DSH 插件安装临时配置
store.path=$TEMP_STORE
NPMRC

echo "=== 最终安装测试 ==="
echo "插件: $PLUGIN"
echo "临时 store: $TEMP_STORE"
echo "临时 HOME: $TEMP_HOME"
echo ""

# 切换到 profile 目录
cd "$HOME/.dsh/profiles/web" || {
    echo "✗ 无法切换到 profile 目录"
    exit 1
}

echo "执行安装命令..."
echo ""

# 执行安装
if HOME="$TEMP_HOME" node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs add "$PLUGIN" 2>&1; then
    echo ""
    echo "✓ 安装成功！"
    echo "请检查 ~/.dsh/profiles/web/package.json 确认插件已添加"
else
    echo ""
    echo "✗ 安装失败"
    echo "查看错误信息，可能需要调整沙盒配置"
fi

echo ""
echo "清理临时目录（可选）:"
echo "  rm -rf $TEMP_STORE $TEMP_HOME"
