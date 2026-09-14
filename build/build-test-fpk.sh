#!/bin/bash
# 构建测试版 FPK 脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== 构建测试版 FPK ==="

# 1. 准备目录
rm -rf fpk-test-build
mkdir -p fpk-test-build
cp -r fpk-extract/* fpk-test-build/

# 2. 替换修改的文件
cp fpk-extract/manifest.test fpk-test-build/manifest
cp fpk-extract/cmd/main.test fpk-test-build/cmd/main
chmod +x fpk-test-build/cmd/main

# 3. 计算 checksum
echo "计算 checksum..."
CHECKSUM=$(sha256sum fpk-test-build/app.tgz | awk '{print $1}')
echo "app.tgz SHA256: $CHECKSUM"

# 4. 更新 manifest 中的 checksum
sed -i "s|checksum        = PLACEHOLDER|checksum        = $CHECKSUM|" fpk-test-build/manifest

# 5. 显示更新后的 manifest
echo ""
echo "=== 更新后的 manifest ==="
cat fpk-test-build/manifest

# 6. 打包 FPK
echo ""
echo "打包 FPK..."
tar -cf fpk-test-build/output.tar -C fpk-test-build .
gzip -9 fpk-test-build/output.tar

# 7. 重命名输出
OUTPUT_NAME="deepseek-harness-test_0.1.0-rc.6.20260817-beta_x86.fpk"
mv fpk-test-build/output.tar.gz "$OUTPUT_NAME"
chmod +x "$OUTPUT_NAME"

# 8. 清理
rm -rf fpk-test-build

# 9. 显示结果
echo ""
echo "=== 构建完成 ==="
ls -lh "$OUTPUT_NAME"
echo ""
echo "测试版 FPK: $OUTPUT_NAME"
echo "正式版 FPK: deepseek-harness_2026.08.17_x86.fpk"
echo ""
echo "两个版本可以共存："
echo "  - 正式版：端口 3080，appname=deepseek-harness"
echo "  - 测试版：端口 3081，appname=deepseek-harness-test"
