#!/bin/bash
# DSH Header Layout - 一键安装/卸载脚本
# 用法: ./dsh-header-layout.sh [install|uninstall|status|toggle]

set -e

DSH_DIR="/vol1/@appshare/DeepSeekHarness/.dsh/profiles/web"
PLUGIN_SRC="/vol1/@appshare/DeepSeekHarness/workspace/dsh-header-layout"
PLUGIN_DEST="${DSH_DIR}/node_modules/dsh-header-layout"
PACKAGE_JSON="${DSH_DIR}/package.json"
CORDIS_PATCH="${DSH_DIR}/cordis.patch.yml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查插件是否已安装
check_status() {
    if [ -d "${PLUGIN_DEST}" ]; then
        log_info "插件已安装在: ${PLUGIN_DEST}"
        if grep -q "dsh-header-layout" "${PACKAGE_JSON}" 2>/dev/null; then
            log_info "package.json 已配置"
        else
            log_warn "package.json 未配置依赖"
        fi
        if grep -q "dsh-header-layout" "${CORDIS_PATCH}" 2>/dev/null; then
            log_info "cordis.patch.yml 已配置"
        else
            log_warn "cordis.patch.yml 未配置"
        fi
    else
        log_warn "插件未安装"
    fi
}

# 安装插件
do_install() {
    log_info "开始安装 DSH Header Layout 插件..."
    
    # 检查源目录
    if [ ! -d "${PLUGIN_SRC}" ]; then
        log_error "源目录不存在: ${PLUGIN_SRC}"
        exit 1
    fi
    
    # 创建目标目录
    mkdir -p "${PLUGIN_DEST}/lib"
    
    # 复制文件
    cp "${PLUGIN_SRC}/package.json" "${PLUGIN_DEST}/"
    cp "${PLUGIN_SRC}/cordis.patch.yml" "${PLUGIN_DEST}/"
    cp "${PLUGIN_SRC}/lib/*.js" "${PLUGIN_DEST}/lib/"
    
    log_info "文件已复制"
    
    # 更新 package.json
    if ! grep -q "dsh-header-layout" "${PACKAGE_JSON}" 2>/dev/null; then
        node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('${PACKAGE_JSON}', 'utf8'));
pkg.dependencies['dsh-header-layout'] = 'file:./node_modules/dsh-header-layout';
fs.writeFileSync('${PACKAGE_JSON}', JSON.stringify(pkg, null, 2) + '\n');
console.log('package.json 已更新');
"
    else
        log_info "package.json 已包含依赖"
    fi
    
    # 更新 cordis.patch.yml
    if ! grep -q "dsh-header-layout" "${CORDIS_PATCH}" 2>/dev/null; then
        cat >> "${CORDIS_PATCH}" << 'EOF'

# DSH Header Layout Plugin - 顶部导航布局
- insert:
    - id: dsh-header-layout
      name: 'dsh-header-layout'
EOF
        log_info "cordis.patch.yml 已更新"
    else
        log_info "cordis.patch.yml 已包含配置"
    fi
    
    log_info "安装完成！请重启 DSH 生效"
    log_info "重启命令: ./start.sh restart"
}

# 卸载插件
do_uninstall() {
    log_info "开始卸载 DSH Header Layout 插件..."
    
    # 删除插件目录
    if [ -d "${PLUGIN_DEST}" ]; then
        rm -rf "${PLUGIN_DEST}"
        log_info "插件目录已删除"
    else
        log_warn "插件目录不存在"
    fi
    
    # 更新 package.json
    if grep -q "dsh-header-layout" "${PACKAGE_JSON}" 2>/dev/null; then
        node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('${PACKAGE_JSON}', 'utf8'));
delete pkg.dependencies['dsh-header-layout'];
fs.writeFileSync('${PACKAGE_JSON}', JSON.stringify(pkg, null, 2) + '\n');
console.log('package.json 已更新');
"
    fi
    
    # 更新 cordis.patch.yml
    if grep -q "dsh-header-layout" "${CORDIS_PATCH}" 2>/dev/null; then
        sed -i '/# DSH Header Layout Plugin/,/name: .dsh-header-layout./d' "${CORDIS_PATCH}"
        log_info "cordis.patch.yml 已更新"
    fi
    
    log_info "卸载完成！请重启 DSH 生效"
    log_info "重启命令: ./start.sh restart"
}

# 切换状态
do_toggle() {
    if [ -d "${PLUGIN_DEST}" ]; then
        log_info "插件已安装，执行卸载..."
        do_uninstall
    else
        log_info "插件未安装，执行安装..."
        do_install
    fi
}

# 主逻辑
case "${1:-status}" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    toggle)
        do_toggle
        ;;
    status|*)
        check_status
        ;;
esac
