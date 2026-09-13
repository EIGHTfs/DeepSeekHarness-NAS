#!/bin/bash
# 验证 DSH CPU 配额是否生效

set -e

echo "=== DSH CPU 配额验证 ==="
echo ""

# 检查 DSH 进程
DSH_PID=$(pgrep -f "runner.js" | head -1)
if [ -z "$DSH_PID" ]; then
    echo "✗ DSH 进程未运行"
    exit 1
fi

echo "DSH PID: $DSH_PID"
echo ""

# 检查 systemd 配置
echo "--- systemd 配置 ---"
CPU_QUOTA=$(systemctl show trim_app_center.service --property=CPUQuota --value)
echo "CPUQuota: $CPU_QUOTA"
echo ""

# 检查 cgroup 限制
echo "--- cgroup 限制 ---"
CGROUP_PATH=$(cat /proc/$DSH_PID/cgroup | cut -d: -f3)
echo "cgroup 路径: $CGROUP_PATH"
if [ -f "/sys/fs/cgroup$CGROUP_PATH/cpu.max" ]; then
    echo "cpu.max:"
    cat "/sys/fs/cgroup$CGROUP_PATH/cpu.max"
else
    echo "无法读取 cpu.max"
fi
echo ""

# 检查进程资源使用
echo "--- 进程资源使用 ---"
ps -p $DSH_PID -o pid,%cpu,%mem,rss,vsz,comm
echo ""

# 检查系统负载
echo "--- 系统负载 ---"
uptime
echo ""

echo "=== 验证完成 ==="
