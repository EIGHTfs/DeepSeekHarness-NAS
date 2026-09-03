#!/bin/bash
# ============================================================
#  fix-dsh-settings-namespace.sh
#  方案 B：修复 dsh-better-sidebar 等插件加载失败
#  「@deepseek-ai/dsh-settings does not provide an export named 'settingsNamespace'」
#
#  背景（2026-09-02 分析闭环）：
#    DSH 从 rc → alpha（0.1.2-alpha.x）升级时，公开 API 发生破坏性变更：
#    删除了 settingsNamespace 命名函数导出（原函数改为私有 parseSettingsNamespace，
#    仅保留 SettingsNamespace 类型导出）。插件 dsh-better-sidebar@0.17.1
#    按 peer ^0.1.0-rc.8 写死 import { settingsNamespace } → ESM SyntaxError。
#
#  本脚本：
#    1) 把私有 parseSettingsNamespace 恢复导出为 settingsNamespace
#    2) 补 rc.2 兼容函数 installSettingsSection（dsh-cloud-workspaces@0.2.1
#       仍 import 该符号；alpha 已改为 SettingsProvider.installSection）
#  同时改 src 和 lib（运行时实际加载 lib），幂等。
#
#  用法: ./fix-dsh-settings-namespace.sh [DSH_DIR]
#        缺省 DSH_DIR = /vol1/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4
#  -d / --dry-run : 只显示将改什么，不写入
#  ============================================================

set -u

DSH_DIR="${1:-/vol1/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4}"
DRY_RUN=0
[ "${2:-}" = "-d" ] || [ "${2:-}" = "--dry-run" ] && DRY_RUN=1

SETTINGS_DIR="$DSH_DIR/packages/settings/settings"
SRC="$SETTINGS_DIR/src/index.ts"
LIB="$SETTINGS_DIR/lib/index.js"

echo "== DSH_DIR   : $DSH_DIR"
echo "== settings  : $SETTINGS_DIR"
echo "== dry-run   : $([ $DRY_RUN -eq 1 ] && echo YES || echo no)"

if [ ! -f "$SRC" ] || [ ! -f "$LIB" ]; then
  echo "❌ 找不到 src/index.ts 或 lib/index.js，路径不对？"
  exit 1
fi

changed=0

# ---------- src/index.ts ----------
if grep -q "export function parseSettingsNamespace" "$SRC"; then
  echo "✅ src: parseSettingsNamespace 已是 export（跳过函数签名）"
else
  echo "→ src: 将 function parseSettingsNamespace 改为 export function ..."
  [ $DRY_RUN -eq 0 ] && sed -i 's/^function parseSettingsNamespace(/export function parseSettingsNamespace(/' "$SRC"
  changed=1
fi

if grep -q "export { parseSettingsNamespace as settingsNamespace }" "$SRC"; then
  echo "✅ src: settingsNamespace 导出已存在（幂等跳过）"
else
  echo "→ src: 追加 export { parseSettingsNamespace as settingsNamespace }"
  [ $DRY_RUN -eq 0 ] && printf '\nexport { parseSettingsNamespace as settingsNamespace }\n' >> "$SRC"
  changed=1
fi

# ---------- lib/index.js ----------
if grep -q "export function parseSettingsNamespace" "$LIB"; then
  echo "✅ lib: parseSettingsNamespace 已是 export（跳过）"
else
  echo "→ lib: 将 function parseSettingsNamespace 改为 export function ..."
  [ $DRY_RUN -eq 0 ] && sed -i 's/^function parseSettingsNamespace(/export function parseSettingsNamespace(/' "$LIB"
  changed=1
fi

if grep -q "parseSettingsNamespace as settingsNamespace" "$LIB"; then
  echo "✅ lib: settingsNamespace 别名导出已存在（幂等跳过）"
else
  echo "→ lib: 在导出行追加 settingsNamespace 别名"
  if [ $DRY_RUN -eq 0 ]; then
    sed -i 's/^export { SettingsConflictError, SettingsProvider, SettingsProvider as default, redactSecrets };/export { SettingsConflictError, SettingsProvider, SettingsProvider as default, redactSecrets, parseSettingsNamespace as settingsNamespace };/' "$LIB"
  fi
  changed=1
fi

# ---------- installSettingsSection（cloud-workspaces / rc.2 插件）----------
if grep -q "export function installSettingsSection" "$SRC"; then
  echo "✅ src: installSettingsSection 已存在（幂等跳过）"
else
  echo "→ src: 追加 installSettingsSection 兼容导出"
  if [ $DRY_RUN -eq 0 ]; then
    cat >> "$SRC" << 'SRCEOF'

/**
 * rc.2 兼容：旧插件（dsh-cloud-workspaces 等）从 `@deepseek-ai/dsh-settings`
 * 直接 import `installSettingsSection`。alpha 已改为实例方法
 * `SettingsProvider.installSection`。无 settings 服务时 hooks 不触发（与 rc.2 一致）。
 */
export function installSettingsSection(ctx, ns, schema, entry, hooks) {
  ctx.inject(['settings'], (scope) => {
    scope.settings.installSection(ctx, ns, schema, entry, hooks)
  })
}
SRCEOF
  fi
  changed=1
fi

if grep -q "function installSettingsSection" "$LIB" && grep -q "installSettingsSection" "$LIB"; then
  echo "✅ lib: installSettingsSection 已存在（幂等跳过）"
else
  echo "→ lib: 追加 installSettingsSection 并加入 export"
  if [ $DRY_RUN -eq 0 ]; then
    # 插在最后一个 export { ... } 之前
    python3 - "$LIB" << 'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
fn = """
function installSettingsSection(ctx, ns, schema, entry, hooks) {
	ctx.inject(["settings"], (scope) => {
		scope.settings.installSection(ctx, ns, schema, entry, hooks);
	});
}
"""
if "function installSettingsSection" not in text:
    text = text.replace(
        "export { SettingsConflictError",
        fn + "export { SettingsConflictError",
        1,
    )
if "installSettingsSection" not in text.split("export {", 1)[-1]:
    text = text.replace(
        "parseSettingsNamespace as settingsNamespace };",
        "parseSettingsNamespace as settingsNamespace, installSettingsSection };",
        1,
    )
    if "installSettingsSection" not in text.split("export {", 1)[-1]:
        text = text.replace(
            "redactSecrets };",
            "redactSecrets, installSettingsSection };",
            1,
        )
p.write_text(text)
PY
  fi
  changed=1
fi

# ---------- 校验 ----------
echo ""
echo "== 校验 =="
if [ $DRY_RUN -eq 0 ]; then
  node --check "$SRC" 2>/dev/null && echo "✅ src 语法 OK" || { echo "⚠️  src 是 TS，node --check 未必适用（TS 语法检查跳过）"; }
  node --check "$LIB" && echo "✅ lib 语法 OK" || echo "❌ lib 语法错误"
  if node --check "$LIB" >/dev/null 2>&1; then
    node -e "
      const m = require('$LIB');
      console.log('  运行时导出检查:');
      console.log('   settingsNamespace =', typeof m.settingsNamespace);
      console.log('   installSettingsSection =', typeof m.installSettingsSection);
      console.log('   SettingsConflictError =', typeof m.SettingsConflictError);
    " 2>&1 | head -5
  fi
else
  echo "(dry-run 不写入，跳过校验)"
fi

echo ""
if [ $DRY_RUN -eq 0 ] && [ $changed -eq 1 ]; then
  echo "✅ 修复完成（src+lib 均已补 settingsNamespace 导出）。"
  echo "   下一步：重启实例让修复生效 → bash start.sh restart"
elif [ $changed -eq 0 ]; then
  echo "ℹ️  无改动（已经是修复后状态）"
else
  echo "ℹ️  dry-run 完成，未写入任何文件"
fi
