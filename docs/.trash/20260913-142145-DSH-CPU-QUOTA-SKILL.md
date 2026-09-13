# DSH CPU 配额配置 Skill

## 概述
为 DeepSeek Harness (DSH) 在飞牛 fnOS 上配置 CPU 配额限制，避免"CPU 过载"误告警。

## 背景知识

### 飞牛 fnOS 架构
- 应用通过 `trim_app_center.service` 管理
- DSH 进程运行在该 service 的 cgroup 下
- 使用 systemd CPUQuota 控制 CPU 使用上限
- cgroup v2 使用 `cpu.max` 文件（格式：`配额 周期`）

### CPU 配额计算
- `cpu.max: 300000 100000` = 300% CPU（3 核）
- `cpu.max: max 100000` = 无限制
- systemd 配置：`CPUQuota=300%`

### 常见陷阱
1. **嵌套 heredoc 变量展开冲突**
   - 外层用 `'EOF'`（单引号）会禁止所有变量展开
   - 内层变量 `$CPU_QUOTA` 会变成字面量而非值
   - 解决：用 `printf` 或分离 heredoc 层级

2. **cgroup 路径动态获取**
   - 不同系统 cgroup 路径可能不同
   - 通过 `/proc/$PID/cgroup` 获取实际路径

## 配置流程

### 一键配置命令
```bash
# 创建配置目录并写入 CPU 配额
mkdir -p /etc/systemd/system/trim_app_center.service.d && \
printf '[Service]\nCPUQuota=300%%\n' > /etc/systemd/system/trim_app_center.service.d/cpu-limit.conf && \
systemctl daemon-reload && \
systemctl restart trim_app_center.service

# 验证配置
systemctl show trim_app_center.service --property=CPUQuota
cat /sys/fs/cgroup/system.slice/trim_app_center.service/cpu.max
```

### 脚本化配置（推荐）
```bash
# 创建配置脚本
cat > /root/scripts/set-dsh-cpu-quota.sh << 'EOF'
#!/bin/bash
set -e
CPU_QUOTA="300%"
SERVICE_NAME="trim_app_center.service"
OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME%.service}.d"
OVERRIDE_FILE="$OVERRIDE_DIR/cpu-limit.conf"

echo "[1/3] 创建 override 目录..."
mkdir -p "$OVERRIDE_DIR"

echo "[2/3] 写入 CPU 配额配置..."
printf '[Service]\nCPUQuota=%s\n' "$CPU_QUOTA" > "$OVERRIDE_FILE"

echo "[3/3] 重载并重启服务..."
systemctl daemon-reload
systemctl restart "$SERVICE_NAME"

echo "验证配置..."
systemctl show "$SERVICE_NAME" --property=CPUQuota
echo "✓ CPU 配额已设置为 $CPU_QUOTA"
EOF

chmod +x /root/scripts/set-dsh-cpu-quota.sh
bash /root/scripts/set-dsh-cpu-quota.sh
```

### 验证脚本
```bash
cat > /root/scripts/verify-dsh-cpu-quota.sh << 'EOF'
#!/bin/bash
DSH_PID=$(pgrep -f "runner.js" | head -1)
if [ -z "$DSH_PID" ]; then
    echo "✗ DSH 进程未运行"
    exit 1
fi

echo "=== DSH CPU 配额验证 ==="
echo "DSH PID: $DSH_PID"
echo ""
echo "--- systemd 配置 ---"
systemctl show trim_app_center.service --property=CPUQuota
echo ""
echo "--- cgroup 限制 ---"
CGROUP_PATH=$(cat /proc/$DSH_PID/cgroup | cut -d: -f3)
echo "cgroup: $CGROUP_PATH"
cat /sys/fs/cgroup$CGROUP_PATH/cpu.max 2>/dev/null || echo "无法读取"
echo ""
echo "--- 进程资源 ---"
ps -p $DSH_PID -o pid,%cpu,%mem,rss,comm
echo ""
echo "--- 系统负载 ---"
uptime
EOF

chmod +x /root/scripts/verify-dsh-cpu-quota.sh
bash /root/scripts/verify-dsh-cpu-quota.sh
```

## 配置文件位置
- Override 目录：`/etc/systemd/system/trim_app_center.service.d/`
- 配置文件：`cpu-limit.conf`
- 内容：
```ini
[Service]
CPUQuota=300%
```

## 持久化
- systemd override 配置重启后自动保留
- 无需额外操作

## 故障排查

### 问题 1：配额未生效
```bash
# 检查配置文件
cat /etc/systemd/system/trim_app_center.service.d/cpu-limit.conf

# 检查 cgroup 实际限制
cat /sys/fs/cgroup/system.slice/trim_app_center.service/cpu.max

# 重新加载
systemctl daemon-reload && systemctl restart trim_app_center.service
```

### 问题 2：嵌套 heredoc 变量未展开
**错误写法**：
```bash
cat > file << 'EOF'
cat > file2 << INNEREOF
$VAR    # 不会展开！
INNEREOF
EOF
```

**正确写法**：
```bash
# 方法 1：用 printf
printf '[Service]\nCPUQuota=%s\n' "$VAR" > file

# 方法 2：分离 heredoc
cat > file << 'EOF'
...（无变量部分）
EOF
cat > file2 << INNEREOF
$VAR    # 可以展开
INNEREOF
```

### 问题 3：cgroup 路径找不到
```bash
# 动态获取 cgroup 路径
DSH_PID=$(pgrep -f "runner.js" | head -1)
CGROUP_PATH=$(cat /proc/$DSH_PID/cgroup | cut -d: -f3)
echo "/sys/fs/cgroup$CGROUP_PATH/cpu.max"
```

## 适用场景
- DSH 在飞牛 fnOS 上运行
- 出现"CPU 过载"误告警
- 需要限制应用 CPU 使用率
- 多实例共存时需要资源隔离

## 相关文件
- `DeepSeekHarness-NAS/scripts/set-dsh-cpu-quota.sh`
- `DeepSeekHarness-NAS/scripts/verify-dsh-cpu-quota.sh`
- `/etc/systemd/system/trim_app_center.service.d/cpu-limit.conf`

---
*创建时间: 2026-08-19*
*作者: Agnes AI*

## 项目文件清单

```
DeepSeekHarness-NAS/
├── scripts/
│   ├── set-dsh-cpu-quota.sh      # CPU 配额配置脚本
│   └── verify-dsh-cpu-quota.sh   # 配置验证脚本
├── docs/
│   └── DSH-CPU-QUOTA-SKILL.md    # 本 skill 文档
└── README.md                     # 已添加 CPU 配额配置章节
```

---
*最后更新: 2026-08-19*
