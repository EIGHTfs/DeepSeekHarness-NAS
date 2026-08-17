# DeepSeekHarness-NAS 故障排除

## 安装成功但启动失败

### 第一步：查看日志

```bash
# SSH 登录群晖后执行

# 查看套件状态
sudo synopkg status DeepSeekHarness

# 查看启动日志
sudo cat /var/log/packages/DeepSeekHarness.log

# 查看应用日志
sudo cat /var/packages/DeepSeekHarness/target/var/logs/dsh.log
sudo cat /var/packages/DeepSeekHarness/target/var/logs/proxy.log

# 实时跟踪日志
sudo tail -f /var/packages/DeepSeekHarness/target/var/logs/dsh.log
```

### 常见错误及解决方案

#### 1. 端口 3080 被占用
```bash
# 检查端口
sudo netstat -tlnp | grep 3080

# 修改端口（编辑 scripts/start-stop-status）
# 将 PORT=3080 改为其他端口（如 3081）
```

#### 2. Node.js 架构不兼容
```bash
# 确认群晖 CPU 架构
sudo uname -m
# x86_64 → 支持 ✅
# aarch64 → 不支持 ❌（需要 arm64 版本）

# 确认安装的 Node.js 版本
/var/packages/DeepSeekHarness/target/bin/node --version
```

#### 3. 权限问题
```bash
# 检查文件权限
ls -la /var/packages/DeepSeekHarness/target/bin/

# 修复权限
sudo chmod 755 /var/packages/DeepSeekHarness/target/bin/node
sudo chmod 755 /var/packages/DeepSeekHarness/target/bin/*.js
```

#### 4. 缺少系统依赖
```bash
# 检查所需的系统库
ldd /var/packages/DeepSeekHarness/target/bin/node 2>&1 | grep "not found"

# 如果有缺失，需要安装相关库
# 对于 x86_64 架构，通常需要:
# - libssl1.1 或 libssl3
# - libc6 等基础库
```

#### 5. 环境变量问题
```bash
# 手动测试启动（SSH 登录后）
export PATH="/var/packages/DeepSeekHarness/target/bin:$PATH"
export DSH_HOME="/var/packages/DeepSeekHarness/target/var"
cd /var/packages/DeepSeekHarness/target
./bin/node ./node_modules/@deepseek-ai/dsh/lib/bin.js web --host 127.0.0.1 --port 3081
# 观察错误输出
```

### 调试模式

启用调试日志：
```bash
# 编辑 start-stop-status，在 start() 函数中添加
export DEBUG="dsh:*"
export NODE_ENV="development"
```

### 查看系统日志
```bash
# 系统日志
sudo dmesg | tail -50
sudo journalctl -u DeepSeekHarness 2>/dev/null || sudo tail -100 /var/log/messages
```

### 重置配置
如果配置损坏导致启动失败：
```bash
# 备份并重置配置
mv /var/packages/DeepSeekHarness/target/var/config /var/packages/DeepSeekHarness/target/var/config.bak
mkdir -p /var/packages/DeepSeekHarness/target/var/config
sudo synopkg restart DeepSeekHarness
```

## 快速诊断脚本

```bash
#!/bin/bash
PKG="/var/packages/DeepSeekHarness/target"
echo "=== DeepSeekHarness 诊断 ==="
echo "1. 状态: $(sudo synopkg status DeepSeekHarness)"
echo "2. Node 版本: $PKG/bin/node --version 2>&1"
echo "3. DSH 入口: $(ls -la $PKG/node_modules/@deepseek-ai/dsh/lib/bin.js 2>&1)"
echo "4. 代理脚本: $(ls -la $PKG/bin/proxy.js 2>&1)"
echo "5. 端口占用:"
sudo netstat -tlnp | grep -E "308[01]" || echo "   无占用"
echo "6. 最近日志:"
sudo tail -20 $PKG/var/logs/dsh.log 2>/dev/null || echo "   无日志"
echo "7. 进程状态:"
pgrep -af "dsh|deepseek" || echo "   无进程"
```
