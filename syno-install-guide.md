# DeepSeek Harness 群晖安装指南

## 📋 前置要求

1. **群晖 DSM 版本**: 7.2 或更高
2. **Node.js**: 需在 Package Center 安装 Node.js 18+
   - 打开群晖 Package Center
   - 搜索 "Node.js"
   - 安装 Node.js 18.x 或更高版本
3. **架构**: x86_64 (Intel/AMD CPU)

## 🚀 安装步骤

### 方法一： Package Center 手动安装（推荐）

1. **下载 spk 文件**
   - 从 Gitee 仓库下载 `DeepSeekHarness-x438-0.1.0-6.spk`

2. **开启允许来源不限**
   - 打开群晖 Package Center
   - 设置 → 包来源 → 选择「任意发行商】

3. **手动安装**
   - 点击「手动安装」
   - 选择下载的 `.spk` 文件
   - 按提示完成安装

4. **配置 API Key**
   - 安装完成后，打开 Web UI: `http://<NAS-IP>:3080`
   - 进入 设置 → Models
   - 配置 DeepSeek 或自定义 API

### 方法二：命令行安装

```bash
# SSH 登录群晖后执行
sudo synopkg install /path/to/DeepSeekHarness-x438-0.1.0-6.spk
```

## 🔧 配置说明

### 首次使用

1. 访问 Web UI: `http://<你的群晖IP>:3080`
2. 进入 **设置 → Models**
3. 添加模型提供方：

**DeepSeek 官方:**
- Provider ID: `deepseek`
- Base URL: `https://api.deepseek.com/v1`
- API Key: `sk-...`

**Agnes AI:**
- Provider ID: `agnes`
- Base URL: `https://api.agnes-ai.cn/v1`
- API Key: `sk-bMu81wEn5t8Fpdhdn2uYSS7pnkdAC9W27PQgGNF8NqzFKkfb`

**本地 Ollama:**
- Provider ID: `ollama`
- Base URL: `http://localhost:11434/v1`
- API Key: 留空

### 端口配置

默认端口：`3080`

如端口冲突，可修改：
```bash
# 编辑启动脚本
vi /var/packages/DeepSeekHarness/target/scripts/upstream
# 修改 PORT=3080 为其他端口
```

## 📊 管理命令

```bash
# 查看状态
sudo synopkg status DeepSeekHarness

# 启动服务
sudo synopkg start DeepSeekHarness

# 停止服务
sudo synopkg stop DeepSeekHarness

# 重启服务
sudo synopkg restart DeepSeekHarness

# 查看日志
sudo tail -f /var/log/packages/DeepSeekHarness.log
```

## 🐛 故障排除

### 问题 1: Node.js 未找到
```bash
# 确认 Node.js 已安装
node --version

# 如未安装，在 Package Center 搜索并安装 Node.js
```

### 问题 2: 端口 3080 被占用
```bash
# 查看端口占用
netstat -tlnp | grep 3080

# 修改为其他端口（如 3081）
# 编辑 scripts/upstream，修改 PORT=3081
```

### 问题 3: 权限问题
```bash
# 检查用户
id deepseek

# 手动创建用户（如不存在）
sudo adduser --system --no-create-home deepseek
```

### 问题 4: 后悔药插件
如果配置错误导致 DSH 无法启动：
```bash
# 进入 DSH 目录
cd /var/packages/DeepSeekHarness/target

# 使用后悔药插件撤销
dsh plugin --profile web remove dsh-undo-savepoint
# 或直接删除配置
rm -rf .dsh/settings.yaml .dsh/.credentials.yaml
```

## 🔄 升级方法

1. 下载最新版本的 `.spk` 文件
2. 在 Package Center 点击「升级」
3. 选择下载的 `.spk` 文件
4. 按提示完成升级

## 📁 文件位置

| 类型 | 路径 |
|------|------|
| 安装目录 | `/var/packages/DeepSeekHarness/target/` |
| 日志文件 | `/var/log/packages/DeepSeekHarness.log` |
| 配置文件 | `/var/packages/DeepSeekHarness/target/.dsh/` |
| 数据目录 | `/var/packages/DeepSeekHarness/target/var/` |

## 🔗 相关链接

- Gitee 仓库: https://gitee.com/Fluquor_Myosotis/fpkDeepSeekHarness
- 原始项目: https://github.com/deepseek-ai/deepseek-harness
- DSH 后悔药: https://github.com/lire1131/dsh-undo-plugin

---
*版本: 0.1.0-6*
*日期: 2026-08-17*
