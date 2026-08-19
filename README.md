# DeepSeekHarness-NAS

> DeepSeek Harness 的飞牛 fnOS / 群晖 DSM 平台适配包

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![DSM](https://img.shields.io/badge/DSM-7.2+-blue)](https://www.synology.com)
[![fnOS](https://img.shields.io/badge/fnOS-2.0+-green)](https://www.flywrc.com)

## 📦 简介

DeepSeek Harness (DSH) 是 DeepSeek AI 官方开源的 Agent 框架，提供 Web UI 管理界面，支持多模型配置、自定义 OpenAI 兼容端点。本仓库提供飞牛 fnOS (.fpk) 和群晖 DSM (.spk) 两个 NAS 平台的适配版本。

### 功能特性

- 🤖 **多模型支持** — DeepSeek 官方模型 + 自定义 OpenAI 兼容端点
- 🔌 **反向代理** — 内置透明反向代理，端口 3080 → 内部 3081
- ⚙️ **Web UI** — 可视化模型管理和配置
- 🔧 **后悔药插件** — 支持一键撤销配置/插件变更
- 🛡️ **安全模式** — DSH 启动失败时可一键禁用所有用户插件

---

## 🚀 快速开始

### 飞牛 fnOS 用户

```bash
# 1. 下载 .fpk 文件
#    从 releases 页面下载 deepseek-harness_*.x86.fpk

# 2. 应用中心安装
#    飞牛 → 应用中心 → 手动安装 → 选择 .fpk

# 3. 访问 Web UI
http://<NAS-IP>:3080
```

### 群晖 DSM 用户

```bash
# 前置条件：确保 DSM 7.2+，x86_64 架构
# 无需额外安装 Node.js（已内置）

# 1. 下载 .spk 文件
#    从 releases 页面下载 DeepSeekHarness-x438-*.spk

# 2. Package Center 手动安装
#    设置 → 包来源 → 任意发行商 → 手动安装 → 选择 .spk

# 3. 访问 Web UI
http://<NAS-IP>:3080
```

---

## ⚙️ 配置自定义 API

### 方法一：Web UI 配置（推荐）

1. 打开 Web UI: `http://<NAS-IP>:3080`
2. 进入 **设置 → Models**
3. 点击「添加提供方」

### 方法二：手动编辑配置文件

配置文件位置：
- 飞牛: `/opt/DeepSeekHarness/.dsh/settings.yaml`
- 群晖: `/var/packages/DeepSeekHarness/target/.dsh/settings.yaml`

**添加 Agnes AI 示例：**

```yaml
providers:
  agnes:
    id: agnes
    name: Agnes AI
    type: openai-completions
    base_url: https://api.agnes-ai.cn/v1
    models:
      - id: agnes-2.5-flash
        name: agnes-2.5-flash
      - id: agnes-2.5-pro
        name: agnes-2.5-pro
      - id: agnes-2.5-pro-alpha
        name: agnes-2.5-pro-alpha
      - id: agnes-2.0-flash
        name: agnes-2.0-flash
      - id: agnes-image-2.1-flash
        name: agnes-image-2.1-flash
      - id: agnes-video-v2.0
        name: agnes-video-v2.0
```

**API Key 配置：**

```bash
# 飞牛
vi /opt/DeepSeekHarness/.dsh/.credentials.yaml

# 群晖
vi /var/packages/DeepSeekHarness/target/.dsh/.credentials.yaml
```

```yaml
API_KEYS:
  AGNES_API_KEY: "sk-你的key"
  DEEPSEEK_API_KEY: "sk-你的key"
```

### 支持的 API 端点示例

| 提供商 | Base URL | 认证方式 |
|--------|----------|----------|
| DeepSeek 官方 | `https://api.deepseek.com/v1` | Bearer Token |
| Agnes AI | `https://api.agnes-ai.cn/v1` | Bearer Token |
| Ollama 本地 | `http://localhost:11434/v1` | 无需 Key |
| Claude API | `https://api.anthropic.com/v1` | Bearer Token |

---

## 🐛 故障排除

### 后悔药插件（一键回滚）

如果配置错误导致 DSH 无法启动：

```bash
# 飞牛
cd /opt/DeepSeekHarness
dsh plugin --profile web add github:lire1131/dsh-undo-plugin#master

# 群晖
cd /var/packages/DeepSeekHarness/target
dsh plugin --profile web add github:lire1131/dsh-undo-plugin#master
```

### 端口冲突

默认端口为 3080（公共）/ 3081（内部），如冲突可修改环境变量：

```bash
# 编辑启动脚本中的 PORT 变量
# 群晖: /var/packages/DeepSeekHarness/scripts/start-stop-status
# 飞牛: /opt/DeepSeekHarness/bin/start.sh
```

### 服务状态管理

```bash
# 群晖
sudo synopkg status DeepSeekHarness
sudo synopkg start DeepSeekHarness
sudo synopkg stop DeepSeekHarness

# 飞牛
# 通过应用中心管理，或直接
ps aux | grep dsh
```

---

## 📁 文件结构

```
DeepSeekHarness-NAS/
├── DeepSeekHarness-x438-*.spk      # 群晖套件包
├── deepseek-harness_*.fpk           # 飞牛插件包
├── README.md                        # 本文档
├── RELEASE-NOTES.md                 # 版本更新说明
├── CHANGELOG.md                     # 变更日志
├── spk/                             # 群晖 spk 源码
│   ├── INFO                         # 套件元数据
│   ├── package.tgz                  # 应用包
│   ├── scripts/
│   │   ├── start-stop-status        # 服务管理
│   │   └── installer                # 生命周期脚本
│   ├── conf/
│   │   ├── privilege                # 权限配置
│   │   └── resource                 # 资源配置
│   └── ui/                          # DSM 界面配置
├── fpk/                             # 飞牛 fpk 源码
│   ├── manifest                     # 飞牛清单
│   ├── cmd/                         # 命令脚本
│   └── config/                      # 配置文件
└── docs/                            # 开发文档
    └── DEVELOPMENT.md
```

---

## 🔗 相关链接

- **原始项目**: https://github.com/deepseek-ai/deepseek-harness
- **DSH 后悔药**: https://github.com/lire1131/dsh-undo-plugin
- **DSH 文档**: https://github.com/deepseek-ai/deepseek-harness/tree/main/docs
- **Agnes AI**: https://agnes-ai.cn

---

## 📄 许可证

MIT License - Copyright (c) 2026 DeepSeek AI

---

## 🔄 当前状态（2026-08-20）

### ✅ 已完成
- [x] DSH 后悔药插件集成（dsh-undo-savepoint v0.3.4）
- [x] Agnes AI 自定义 API 配置（6 个模型）
- [x] 飞牛 fnOS .fpk 包分析
- [x] **rc.7 修复版 fpk 打包**（`0.1.0-rc.7.20260820b`，独立 appname `deepseek-harness-rc7`）
  - ✅ **DSH_HOME 锁定**：rc.7 数据完全独立（`/vol1/@appdata/deepseek-harness-rc7/.dsh`），不再污染主环境
  - ✅ **config 去 data-share**：安装不再创建共享软链
  - ✅ 主环境 3081 零影响（软链 0 污染，实测）
  - 📄 修复详情见 `docs/rc7-fix-20260820.md`
- [x] 群晖 DSM .spk 包结构构建
- [x] 完整开发文档（README、CHANGELOG、DEVELOPMENT 等）

### 📋 待办事项
1. 修复 spk 启动问题（需要日志）
2. 在真实群晖环境完整测试
3. 大文件通过 GitHub Releases 发布（仓库不含编译好的 fpk/tgz）
4. 准备图标资源（banner/logo/background）
5. 完善 CHANGELOG

### 🐛 已知问题
- Git HTTPS 不可用（容器限制），需手动推送
- fpk/spk 大文件通过 GitHub Releases 发布（不入 git，见 .gitignore）

---

*最后更新: 2026-08-20 03:20*

---

## 🔧 CPU 配额配置

为避免"CPU 过载"误告警，建议为 DSH 配置 CPU 配额限制。

### 快速配置（飞牛 fnOS）

```bash
# SSH 连接到 NAS 后执行
mkdir -p /etc/systemd/system/trim_app_center.service.d && \
printf '[Service]\nCPUQuota=300%%\n' > /etc/systemd/system/trim_app_center.service.d/cpu-limit.conf && \
systemctl daemon-reload && \
systemctl restart trim_app_center.service

# 验证
systemctl show trim_app_center.service --property=CPUQuota
cat /sys/fs/cgroup/system.slice/trim_app_center.service/cpu.max
```

### 详细文档
见 [docs/DSH-CPU-QUOTA-SKILL.md](docs/DSH-CPU-QUOTA-SKILL.md)

### 脚本工具
- `scripts/set-dsh-cpu-quota.sh` - 配置 CPU 配额
- `scripts/verify-dsh-cpu-quota.sh` - 验证配置状态

---
