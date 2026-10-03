#!/bin/bash
# ============================================================
#  pnpm store 权限测试与修复脚本
#  用途：诊断并尝试修复 pnpm store SQLite 权限问题
#  用法：bash scripts/test-pnpm-store-fix.sh [--fix]
# ============================================================

set -u

STORE_PATH="/vol2/1000/DeepSeek Harness/.pnpm-store"
INDEX_DB="${STORE_PATH}/v11/index.db"
LOG_FILE="/tmp/pnpm-store-diag-$(date +%Y%m%d-%H%M%S).log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

section() {
    echo ""
    log "============================================================"
    log "  $*"
    log "============================================================"
}

# ============================================================
# 1. 诊断当前状态
# ============================================================
section "1. 环境诊断"

log "当前用户: $(whoami) (uid=$(id -u), gid=$(id -g))"
log "DSH_HOME: ${DSH_HOME:-未设置}"
log "PNPM_HOME: ${PNPM_HOME:-未设置}"
log "日志文件: $LOG_FILE"

# 检查 pnpm store 路径
if [ -d "$STORE_PATH" ]; then
    log "${GREEN}✓${NC} pnpm store 目录存在: $STORE_PATH"
    ls -ld "$STORE_PATH" | while read -r line; do log "  $line"; done
else
    log "${RED}✗${NC} pnpm store 目录不存在: $STORE_PATH"
fi

# 检查 index.db
if [ -f "$INDEX_DB" ]; then
    log "${GREEN}✓${NC} index.db 存在: $INDEX_DB"
    ls -l "$INDEX_DB" | awk '{print "  权限:", $1, "| 所有者:", $3":"$4, "| 大小:", $5, "bytes"}'
    
    # 测试写入权限
    if touch "$INDEX_DB" 2>/dev/null; then
        log "${GREEN}✓${NC} index.db 可写"
        rm -f "$INDEX_DB.touch_test"
    else
        log "${RED}✗${NC} index.db 不可写（权限不足）"
    fi
else
    log "${YELLOW}⚠${NC} index.db 不存在，将尝试创建"
fi

# 检查文件系统挂载状态
log ""
log "文件系统挂载信息:"
mount | grep -E "(vol2|DeepSeek)" | head -5 | while read -r line; do
    log "  $line"
done

# 检查是否只读挂载
if mount | grep -qE "(vol2|DeepSeek).*\bro\b"; then
    log "${RED}✗${NC} 检测到只读挂载！"
    log "   需要重新挂载为读写模式："
    log "   mount -o remount,rw '/vol2/1000/DeepSeek Harness'"
else
    log "${GREEN}✓${NC} 文件系统未标记为只读"
fi

# ============================================================
# 2. 尝试修复（仅在 --fix 参数时执行）
# ============================================================
FIX_MODE=false
if [[ "${1:-}" == "--fix" ]]; then
    FIX_MODE=true
    log ""
    log "${YELLOW}⚠${NC} 检测到 --fix 参数，将尝试自动修复"
fi

if $FIX_MODE; then
    section "2. 尝试修复"
    
    # 尝试 1: 修改文件权限
    log ""
    log "尝试 1: 修改文件权限..."
    if chmod -R u+w "$STORE_PATH" 2>/dev/null; then
        log "${GREEN}✓${NC} 权限修改成功"
    else
        log "${RED}✗${NC} 权限修改失败（可能需要 sudo）"
    fi
    
    # 尝试 2: 检查是否还是只读
    if mount | grep -qE "(vol2|DeepSeek).*\bro\b"; then
        log ""
        log "${RED}✗${NC} 文件系统仍为只读挂载"
        log "   需要手动执行（需要 root 权限）："
        log "   sudo mount -o remount,rw '/vol2/1000/DeepSeek Harness'"
    else
        log "${GREEN}✓${NC} 文件系统已确认可写"
    fi
    
    # 尝试 3: 测试 pnpm 命令
    log ""
    log "尝试 3: 测试 pnpm store path..."
    if node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs store path 2>&1; then
        log "${GREEN}✓${NC} pnpm store path 命令正常"
    else
        log "${RED}✗${NC} pnpm store path 命令失败"
    fi
else
    section "2. 修复建议（未执行，需手动运行）"
    log ""
    log "如需自动修复，请运行："
    log "  bash scripts/test-pnpm-store-fix.sh --fix"
    log ""
    log "或手动执行以下命令（需要 root/sudo 权限）："
    log ""
    log "  # 1. 重新挂载为读写模式"
    log "  sudo mount -o remount,rw '/vol2/1000/DeepSeek Harness'"
    log ""
    log "  # 2. 修改 pnpm store 权限"
    log "  sudo chmod -R u+w '$STORE_PATH'"
    log ""
    log "  # 3. 验证修复"
    log "  bash scripts/test-pnpm-store-fix.sh"
fi

# ============================================================
# 3. 替代方案
# ============================================================
section "3. 替代方案"

log ""
log "如果无法修改 /vol2/1000 的权限，可考虑以下方案："
log ""
log "方案 A: 更改 pnpm store 位置"
log "  1. 创建新的 store 目录："
log "     mkdir -p ~/pnpm-store"
log "  2. 配置 pnpm："
log "     echo 'store.path=~/.local/share/pnpm/store' > ~/.npmrc"
log "  3. 重新运行插件安装命令"
log ""
log "方案 B: 使用 CACHEDIR 环境变量"
log "  export COREPACK_CACHE_DIR=~/cache"
log "  export PNPM_HOME=~/pnpm"
log "  dsh plugin --profile web add dsh-edit-diff"
log ""
log "方案 C: 联系系统管理员"
log "  请求将 '/vol2/1000' 挂载为读写模式，或授予对 pnpm store 的写入权限"

# ============================================================
# 4. 最终状态检查
# ============================================================
section "4. 最终状态检查"

if [ -f "$INDEX_DB" ]; then
    if touch "$INDEX_DB" 2>/dev/null; then
        log "${GREEN}✓${NC} index.db 现在可写"
        rm -f "$INDEX_DB.touch_test"
    else
        log "${RED}✗${NC} index.db 仍不可写"
    fi
fi

log ""
log "诊断完成。详细信息请查看: $LOG_FILE"
