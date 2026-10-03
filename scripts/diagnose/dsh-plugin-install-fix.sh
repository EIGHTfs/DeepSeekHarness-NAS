#!/bin/bash
# ============================================================
#  DSH 插件安装修复脚本
#  用途：解决 /vol2 只读挂载导致的 pnpm store 写入失败问题
#  作者：AI Agent
#  日期：2026-09-16
# ============================================================

set -u

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 路径配置
DSH_DIR="/vol2/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4"
WORKSPACE="$DSH_DIR/.dsh-home/工作区/DeepSeekHarness-NAS"
PROFILES_DIR="$HOME/.dsh/profiles/web"
TEMP_BASE="/tmp/dsh-fix-$$"

# 创建临时工作目录
mkdir -p "$TEMP_BASE"/{store,cache,npmrc}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "$msg" | tee -a "$TEMP_BASE/install.log"
}

section() {
    echo ""
    log "${BLUE}============================================================${NC}"
    log "${BLUE}  $*${NC}"
    log "${BLUE}============================================================${NC}"
}

# ============================================================
# 1. 诊断当前状态
# ============================================================
section "1. 环境诊断"

log "当前用户: $(whoami) (uid=$(id -u))"
log "工作目录: $WORKSPACE"
log "临时目录: $TEMP_BASE"

# 检查 /vol2 挂载状态
if mount | grep -qE "/vol2.*\bro\b"; then
    log "${RED}✗ 检测到 /vol2 为只读挂载${NC}"
    log "   这是根本原因，需要重新挂载或绕过"
else
    log "${GREEN}✓ /vol2 挂载状态正常${NC}"
fi

# 检查 pnpm store
ORIGINAL_STORE="$DSH_DIR/.pnpm-store/v11"
if [ -f "$ORIGINAL_STORE/index.db" ]; then
    log "原始 store: $ORIGINAL_STORE"
    if touch "$ORIGINAL_STORE/index.db" 2>/dev/null; then
        log "${GREEN}✓ 原始 store 可写${NC}"
        rm -f "$ORIGINAL_STORE/index.db.touch_test"
    else
        log "${RED}✗ 原始 store 不可写（确认权限问题）${NC}"
    fi
fi

# ============================================================
# 2. 解决方案
# ============================================================
section "2. 解决方案"

log ""
log "由于 /vol2 为只读挂载，有以下方案："
log ""
log "${YELLOW}方案 A: 重新挂载为读写（需要 root 权限）${NC}"
log "  mount -o remount,rw /vol2"
log ""
log "${YELLOW}方案 B: 使用临时目录作为 pnpm store（推荐）${NC}"
log "  将 pnpm store 切换到 /tmp 下的可写目录"
log ""
log "${YELLOW}方案 C: 联系系统管理员${NC}"
log "  请求永久修改 /vol2 挂载选项"

# ============================================================
# 3. 执行方案 B：使用临时 store
# ============================================================
section "3. 配置临时 pnpm store"

TEMP_STORE="$TEMP_BASE/store"
TEMP_NPMRC="$TEMP_BASE/npmrc/.npmrc"

# 创建配置文件
cat > "$TEMP_NPMRC" << NPMRC
# DSH 插件安装临时配置（$(date '+%Y-%m-%d %H:%M:%S')）
# 避免只读文件系统问题
store.path=$TEMP_STORE
NPMRC

log "临时 store 目录: $TEMP_STORE"
log "配置文件: $TEMP_NPMRC"
log ""
cat "$TEMP_NPMRC"

# 测试写入
if touch "$TEMP_STORE/test.txt" 2>/dev/null; then
    log "${GREEN}✓ 临时 store 目录可写${NC}"
    rm -f "$TEMP_STORE/test.txt"
else
    log "${RED}✗ 临时 store 目录不可写${NC}"
    exit 1
fi

# ============================================================
# 4. 安装插件命令
# ============================================================
section "4. 安装插件命令"

PLUGIN_NAME="${1:-dsh-edit-diff}"

log ""
log "安装插件: $PLUGIN_NAME"
log ""
log "使用以下命令执行安装："
log ""
log "${GREEN}HOME=$TEMP_BASE \\"${NC}"
log "${GREEN}  npm config set store.path $TEMP_STORE && \\"${NC}"
log "${GREEN}  dsh plugin --profile web add $PLUGIN_NAME${NC}"
log ""
log "或者直接使用 pnpm："
log ""
log "${GREEN}cd $PROFILES_DIR && \\"${NC}"
log "${GREEN}  HOME=$TEMP_BASE node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs add $PLUGIN_NAME${NC}"
log ""

# ============================================================
# 5. 实际安装（如果指定 --install）
# ============================================================
if [[ "${2:-}" == "--install" ]]; then
    section "5. 执行安装"
    
    log "开始安装 $PLUGIN_NAME..."
    log ""
    
    # 切换到 profile 目录
    cd "$PROFILES_DIR" || {
        log "${RED}✗ 无法切换到 profile 目录${NC}"
        exit 1
    }
    
    # 执行安装
    if HOME="$TEMP_BASE" node /root/.cache/node/corepack/v1/pnpm/11.7.0/dist/pnpm.mjs add "$PLUGIN_NAME" 2>&1; then
        log "${GREEN}✓ 插件安装成功${NC}"
        log "插件已添加到 $PROFILES_DIR/package.json"
    else
        log "${RED}✗ 插件安装失败${NC}"
        log "查看日志: $TEMP_BASE/install.log"
        exit 1
    fi
else
    section "5. 安装说明"
    log ""
    log "如需自动安装，请运行："
    log "  bash scripts/dsh-plugin-install-fix.sh $PLUGIN_NAME --install"
    log ""
    log "注意：安装完成后，建议清理临时目录："
    log "  rm -rf $TEMP_BASE"
fi

# ============================================================
# 6. 清理说明
# ============================================================
section "6. 清理说明"

log ""
log "临时文件位置: $TEMP_BASE"
log ""
log "清理命令："
log "  rm -rf $TEMP_BASE"
log ""
log "日志文件: $TEMP_BASE/install.log"

# ============================================================
# 完成
# ============================================================
echo ""
log "${GREEN}诊断完成。${NC}"
log "如需帮助，请查看日志: $TEMP_BASE/install.log"
echo ""
