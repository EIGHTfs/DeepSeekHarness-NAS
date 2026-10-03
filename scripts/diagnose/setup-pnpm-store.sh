#!/bin/bash
# ============================================================
#  设置替代 pnpm store 位置
#  用途：当默认 pnpm store 不可写时，配置到用户可写目录
#  用法：bash scripts/setup-pnpm-store.sh [--apply]
# ============================================================

set -u

NEW_STORE_DIR="${HOME}/.local/share/pnpm/store"
NPMRC_FILE="${HOME}/.npmrc"
BACKUP_SUFFIX=".bak-$(date +%Y%m%d-%H%M%S)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

section() {
    echo ""
    log "============================================================"
    log "  $*"
    log "============================================================"
}

# 检查当前配置
section "1. 当前配置检查"

if [ -f "$NPMRC_FILE" ]; then
    log "现有 .npmrc: $NPMRC_FILE"
    grep -E "store\.path|pnpm" "$NPMRC_FILE" 2>/dev/null | while read -r line; do
        log "  $line"
    done
else
    log "无现有 .npmrc 文件"
fi

# 检查新目录
if [ -d "$NEW_STORE_DIR" ]; then
    log "新 store 目录已存在: $NEW_STORE_DIR"
    ls -ld "$NEW_STORE_DIR" | awk '{print "  权限:", $1, "| 所有者:", $3":"$4}'
else
    log "新 store 目录不存在: $NEW_STORE_DIR"
fi

# 测试写入权限
TEST_FILE="${NEW_STORE_DIR}/.write_test_$$"
mkdir -p "$(dirname "$TEST_FILE")" 2>/dev/null
if touch "$TEST_FILE" 2>/dev/null; then
    log "✓ 新目录可写"
    rm -f "$TEST_FILE"
else
    log "✗ 新目录不可写"
fi

# 应用配置
APPLY=false
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=true
    log ""
    log "⚠ 检测到 --apply 参数，将自动配置"
fi

if $APPLY; then
    section "2. 配置 pnpm store"
    
    # 创建目录
    log "创建 store 目录..."
    mkdir -p "$NEW_STORE_DIR"
    
    # 备份现有 .npmrc
    if [ -f "$NPMRC_FILE" ]; then
        log "备份现有 .npmrc..."
        cp "$NPMRC_FILE" "${NPMRC_FILE}${BACKUP_SUFFIX}"
    fi
    
    # 写入配置
    log "写入 pnpm store 配置..."
    echo "" >> "$NPMRC_FILE"
    echo "# pnpm store 配置（$(date '+%Y-%m-%d %H:%M:%S')）" >> "$NPMRC_FILE"
    echo "store.path=${NEW_STORE_DIR}" >> "$NPMRC_FILE"
    
    # 验证配置
    log "验证配置..."
    if node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path 2>&1 | grep -q "$NEW_STORE_DIR"; then
        log "✓ 配置成功！pnpm store 已切换到: $NEW_STORE_DIR"
    else
        log "⚠ 配置可能未生效，请手动检查"
    fi
    
    log ""
    log "下一步：重新运行插件安装命令"
    log "  dsh plugin --profile web add dsh-edit-diff"
else
    section "2. 配置命令（手动执行）"
    log ""
    log "请手动执行以下命令配置替代 store："
    log ""
    log "  # 1. 创建新 store 目录"
    log "  mkdir -p ${NEW_STORE_DIR}"
    log ""
    log "  # 2. 写入配置到 ~/.npmrc"
    log "  echo '' >> ~/.npmrc"
    log "  echo 'store.path=${NEW_STORE_DIR}' >> ~/.npmrc"
    log ""
    log "  # 3. 验证配置"
    log "  node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path"
    log ""
    log "或使用一键命令："
    log "  bash scripts/setup-pnpm-store.sh --apply"
fi

section "3. 完成"
log ""
log "配置完成后，重新运行插件安装命令即可。"
log "日志文件: /tmp/pnpm-store-setup-$(date +%Y%m%d-%H%M%S).log"
