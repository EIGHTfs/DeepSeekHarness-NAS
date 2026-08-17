# DeepSeekHarness-NAS 快速上手

## 🚀 立即可用

### 飞牛 fnOS 用户
```bash
# 1. 下载 fpk
# 从 Gitee 仓库下载 deepseek-harness_*.fpk

# 2. 应用中心安装
# 飞牛 → 应用中心 → 手动安装 → 选择 .fpk

# 3. 访问 Web UI
http://<NAS-IP>:3080
```

### 群晖 DSM 用户（开发中）
```bash
# 前置条件
# 1. Package Center 安装 Node.js 18+

# 2. 下载 spk（待构建完成）
# 从 Gitee 仓库下载 DeepSeekHarness-*.spk

# 3. 手动安装
# Package Center → 手动安装 → 选择 .spk

# 4. 访问 Web UI
http://<NAS-IP>:3080
```

## 📁 文件说明

| 文件 | 用途 |
|------|------|
| `deepseek-harness_*.fpk` | 飞牛插件包（主程序） |
| `syno-spk/` | 群晖套件源码（开发中） |
| `README.md` | 详细文档 |
| `upload.sh` | GitHub/Gitee 上传脚本 |

## 🔧 配置自定义 API

安装后在 Web UI 操作：
1. 进入 **设置 → Models**
2. 点击「添加提供方」
3. 填写：
   - Provider ID: `agnes`
   - Base URL: `https://api.agnes-ai.cn/v1`
   - API Key: `sk-...`
4. 保存并选择默认模型

## 🐛 故障排除

### 端口冲突
```bash
# 修改端口（环境变量）
export DSH_PORT=3081
```

### 后悔药插件
```bash
# 如果改坏配置，一键撤销
dsh plugin --profile web add github:lire1131/dsh-undo-plugin#master
```

## 📞 支持

- Gitee: https://gitee.com/Fluquor_Myosotis/DeepSeekHarness-NAS
- 原始项目: https://github.com/deepseek-ai/deepseek-harness
- DSH 后悔药: https://github.com/lire1131/dsh-undo-plugin

---
*最后更新: 2026-08-17*
