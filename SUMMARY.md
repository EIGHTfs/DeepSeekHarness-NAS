# DeepSeekHarness-NAS 项目总结

## 📦 项目目标
将飞牛 fnOS 的 DeepSeek Harness (.fpk) 移植到群晖 DSM 7.2 (.spk)

## ✅ 当前进度

### 已完成
| 任务 | 状态 | 说明 |
|------|------|------|
| Gitee 仓库创建 | ✅ | https://gitee.com/Fluquor_Myosotis/DeepSeekHarness-NAS |
| fpk 包分析 | ✅ | 108MB, x86_64, Node.js 24 |
| DSH 后悔药插件 | ✅ | dsh-undo-savepoint v0.3.4 |
| Agnes AI 配置 | ✅ | 6 个模型已验证 |
| spk info 文件 | ✅ | 群晖套件元数据 |
| spk 安装脚本 | ✅ | upstream/downstream |
| 开发文档 | ✅ | DEVELOPMENT.md |

### 待完成
| 任务 | 优先级 | 说明 |
|------|--------|------|
| fpk 大文件上传 | 高 | 108MB，需 Gitee LFS 或手动 |
| spk 构建测试 | 中 | 需要群晖环境验证 |
| 图标资源 | 低 | banner/logo/background |

## 📁 文件结构

```
DeepSeekHarness-NAS/
├── README.md              # 项目说明（中文）
├── upload.sh              # Gitee/GitHub 上传脚本
├── DEVELOPMENT.md         # 开发进展记录
├── SUMMARY.md            # 本文件
├── syno-spk/             # 群晖 spk 包
│   ├── info              # 套件元数据
│   └── scripts/
│       ├── upstream      # 安装/启动脚本
│       └── downstream    # 卸载脚本
└── deepseek-harness_*.fpk # 飞牛插件包（大文件）
```

## 🔧 技术栈

- **运行时**: Node.js v24.4.0
- **框架**: DeepSeek Harness (dsh)
- **目标平台**: 群晖 DSM 7.2, x86_64
- **端口**: 3080
- **认证**: Gitee PAT (Personal Access Token)

## 🚀 部署方式

### 群晖用户
1. 确保已安装 Node.js 18+（Package Center）
2. 下载 .spk 文件
3. 手动安装（允许第三方来源）
4. 访问 http://<NAS-IP>:3080

### 飞牛用户
1. 下载 .fpk 文件
2. 应用中心 → 手动安装
3. 配置 API Key
4. 访问 http://<NAS-IP>:3080

## 📝 已知限制

1. **Git HTTPS**: 容器内 git 不支持 HTTPS，需手动上传大文件
2. **Node.js 依赖**: 群晖版需用户先装 Node.js 18+
3. **端口冲突**: 默认 3080，可能与已有服务冲突

## 🔗 相关链接

- Gitee: https://gitee.com/Fluquor_Myosotis/DeepSeekHarness-NAS
- 原始项目: https://github.com/deepseek-ai/deepseek-harness
- DSH 后悔药: https://github.com/lire1131/dsh-undo-plugin

---
*创建时间: 2026-08-17*
*最后更新: 2026-08-17*
