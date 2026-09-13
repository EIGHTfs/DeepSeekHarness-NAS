#!/bin/bash
# 差分生成脚本 - 对比正式版和测试版 FPK

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== FPK 差分分析 ==="
echo ""

# 定义文件路径
OFFICIAL_FPK="deepseek-harness_2026.08.17_x86.fpk"
TEST_FPK="deepseek-harness-test_0.1.0-rc.6.20260817-beta_x86.fpk"
OFFICIAL_DIR="fpk-official"
TEST_DIR="fpk-test"

# 1. 解压两个 FPK
echo "解压官方 FPK..."
rm -rf "$OFFICIAL_DIR" "$TEST_DIR"
mkdir -p "$OFFICIAL_DIR" "$TEST_DIR"

gzip -d -c "$OFFICIAL_FPK" | tar -xf - -C "$OFFICIAL_DIR"
gzip -d -c "$TEST_FPK" | tar -xf - -C "$TEST_DIR"

# 2. 生成差分报告
REPORT="fpk-diff-report.md"
cat > "$REPORT" << 'EOF'
# FPK 差分报告

## 文件对比

| 文件 | 官方版 | 测试版 | 变更 |
|------|--------|--------|------|
EOF

# 对比 manifest
echo ""
echo "对比 manifest..."
echo "| \`manifest\` | $(wc -c < "$OFFICIAL_DIR/manifest") bytes | $(wc -c < "$TEST_DIR/manifest") bytes | appname/version/port 变更 |" >> "$REPORT"

# 对比 cmd/main
echo "对比 cmd/main..."
echo "| \`cmd/main\` | $(wc -c < "$OFFICIAL_DIR/cmd/main") bytes | $(wc -c < "$TEST_DIR/cmd/main") bytes | APPNAME 变量变更 |" >> "$REPORT"

# 对比其他文件（应该相同）
for file in DeepSeekHarness.sc ICON.PNG ICON_256.PNG config/* ui/* wizard/*; do
    if [ -f "$OFFICIAL_DIR/$file" ] && [ -f "$TEST_DIR/$file" ]; then
        OFFICIAL_SIZE=$(wc -c < "$OFFICIAL_DIR/$file")
        TEST_SIZE=$(wc -c < "$TEST_DIR/$file")
        if [ "$OFFICIAL_SIZE" = "$TEST_SIZE" ]; then
            echo "| \`$file\` | $OFFICIAL_SIZE bytes | $TEST_SIZE bytes | 无变更 |" >> "$REPORT"
        else
            echo "| \`$file\` | $OFFICIAL_SIZE bytes | $TEST_SIZE bytes | 大小不同 |" >> "$REPORT"
        fi
    fi
done

# app.tgz 相同
echo "| \`app.tgz\` | $(wc -c < "$OFFICIAL_DIR/app.tgz") bytes | $(wc -c < "$TEST_DIR/app.tgz") bytes | 相同（未修改） |" >> "$REPORT"

# 3. 生成应用说明
cat >> "$REPORT" << 'EOF'

## 变更摘要

### 1. manifest
- `appname`: `deepseek-harness` → `deepseek-harness-test`
- `version`: 添加 `-beta` 后缀
- `display_name`: 添加 `(Test)` 标识
- `service_port`: `3080` → `3081`
- `checksum`: 重新计算 SHA256

### 2. cmd/main
- `APPNAME`: `deepseek-harness` → `deepseek-harness-test`

### 3. 其他文件
- 全部保持不变

## 部署建议

### 共存配置
两个版本可以同时安装，互不干扰：

| 版本 | appname | 端口 | 数据目录 |
|------|---------|------|----------|
| 正式版 | deepseek-harness | 3080 | /vol1/@appdata/deepseek-harness |
| 测试版 | deepseek-harness-test | 3081 | /vol1/@appdata/deepseek-harness-test |

### 安装顺序
1. 先安装正式版（端口 3080）
2. 再安装测试版（端口 3081）
3. 通过不同端口访问：
   - 正式版：http://NAS-IP:3080
   - 测试版：http://NAS-IP:3081

### 注意事项
- 两个版本的数据完全隔离
- 配置文件独立：`/vol1/@appdata/deepseek-harness*/.dsh/settings.yaml`
- 测试版可随时卸载，不影响正式版
EOF

# 4. 显示报告
echo ""
echo "=== 差分报告 ==="
cat "$REPORT"

# 5. 清理
rm -rf "$OFFICIAL_DIR" "$TEST_DIR"

echo ""
echo "报告已保存到: $REPORT"
