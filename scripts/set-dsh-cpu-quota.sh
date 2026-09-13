#!/bin/bash
# DSH CPU 配额限制脚本
# 限制 DeepSeek Harness 使用 300% CPU（3 核）

set -e

echo "=== DSH CPU 配额配置 ==="
echo ""

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "错误: 需要 root 权限"
    echo "请执行: sudo $0"
    exit 1
fi

# 配置参数
CPU_QUOTA="300%"
SERVICE_NAME="trim_app_center.service"
OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME%.service}.d"
OVERRIDE_FILE="$OVERRIDE_DIR/cpu-limit.conf"

echo "配置参数:"
echo "  服务: $SERVICE_NAME"
echo "  CPU 配额: $CPU_QUOTA"
echo "  配置目录: $OVERRIDE_DIR"
echo "  配置文件: $OVERRIDE_FILE"
echo ""

# 1. 创建 override 目录
echo "[1/4] 创建 override 目录..."
mkdir -p "$OVERRIDE_DIR"
echo "✓ 目录创建完成"

# 2. 写入配置文件
echo ""
echo "[2/4] 写入 CPU 配额配置..."
cat > "$OVERRIDE_FILE" << EOF
[Service]
CPUQuota=$CPU_QUOTA
EOF
echo "✓ 配置已写入"
echo "  内容:"
cat "$OVERRIDE_FILE" | sed 's/^/  /'

# 3. 重载 systemd 配置
echo ""
echo "[3/4] 重载 systemd 配置..."
systemctl daemon-reload
echo "✓ 配置已重载"

# 4. 重启服务
echo ""
echo "[4/4] 重启应用中心服务..."
systemctl restart "$SERVICE_NAME"
echo "✓ 服务已重启"

# 验证配置
echo ""
echo "=== 验证配置 ==="
CPU_QUOTA_CURRENT=$(systemctl show "$SERVICE_NAME" --property=CPUQuota --value)
echo "当前 CPU 配额: $CPU_QUOTA_CURRENT"

if echo "$CPU_QUOTA_CURRENT" | grep -q "300"; then
    echo "✓ CPU 配额限制成功应用到 $SERVICE_NAME"
else
    echo "⚠ 配额可能未生效，请检查配置"
fi

echo ""
echo "=== 完成 ==="
echo "DSH 应用现在受 300% CPU 配额限制"
echo "重启后配置会自动保留"
echo ""
echo "查看进程状态:"
echo "  systemctl status $SERVICE_NAME"
echo "  ps aux | grep runner.js"
