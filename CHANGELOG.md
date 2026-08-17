# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0-6] - 2026-08-17

### Added
- 群晖 DSM 7.2+ spk 包支持
- 飞牛 fnOS fpk 包支持
- Node.js v24.4.0 内置运行时
- 透明反向代理（bin/proxy.js）
- 后悔药插件（dsh-undo-savepoint）
- README 文档（中英文）
- 安装指南

### Fixed
- spk 包格式修正（外层使用未压缩 tar）
- 启动入口路径修正（@deepseek-ai/dsh/lib/bin.js）
- 权限设置修正（755/644）

### Notes
- 首次版本发布
- 感谢 [Fluquor_Myosotis](https://gitee.com/Fluquor_Myosotis) 的适配工作

---

## [0.1.0-rc.6] - 2026-08-14

### Added
- DeepSeek Harness 核心框架
- Web UI 管理界面
- 多模型配置系统
- OpenAI 兼容 API 端点

## [0.1.0-6] - 2026-08-17 (hotfix)

### Fixed
- 修复启动失败问题：Node.js 需要 `--expose-internals` 参数支持 HMR 服务
- 更新 start-stop-status 脚本添加正确参数
