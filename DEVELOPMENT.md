# DeepSeekHarness-NAS 开发进展记录

## 项目概述
将飞牛 fnOS 的 DeepSeek Harness (.fpk) 移植到群晖 DSM 7.2 (.spk)

## 当前状态

### ✅ 已完成
1. **Gitee 仓库创建**
   - 仓库地址: https://gitee.com/Fluquor_Myosotis/DeepSeekHarness-NAS
   - 所有者: Fluquor_Myosotis
   - 状态: 公开仓库

2. **fpk 包分析**
   - 版本: deepseek-harness_2026.08.17_x86.fpk (108MB)
   - 结构: manifest + cmd scripts + app.tgz + ui/wizard/config
   - Node.js 版本: v24.4.0
   - 架构: x86_64

3. **DSH "后悔药" 插件安装**
   - 插件名: dsh-undo-savepoint v0.3.4
   - 状态: ✅ 已安装并验证
   - 位置: .dsh/profiles/web/node_modules/dsh-undo-savepoint/

4. **自定义 API 配置**
   - Agnes AI: https://api.agnes-ai.cn/v1
   - 模型: 6 个（agnes-2.0-flash 到 agnes-video-v2.0）
   - 状态: ✅ 已配置并验证

5. **群晖 spk 基础结构**
   - info 文件: ✅ 已创建
   - upstream 脚本: ✅ 已创建
   - downstream 脚本: ✅ 已创建

### ⏳ 进行中
- [ ] Gitee 大文件上传（fpk 108MB 需要 Gitee LFS 或手动上传）
- [ ] spk 构建脚本完善
- [ ] 图标资源准备

### ⏸️ 待办
- [ ] 测试群晖环境部署
- [ ] 端口配置优化
- [ ] 文档完善

## 技术问题记录

### 1. Git HTTPS 不支持
- **问题**: 容器内 git 缺少 remote-https 支持
- **影响**: 无法直接 git push
- **解决方案**: 使用 Gitee API 上传文件
- **状态**: ✅ 已绕过

### 2. GitHub 网络阻断
- **问题**: 国内网络环境阻断 GitHub（TLS 握手失败）
- **影响**: 无法直接推送 GitHub
- **解决方案**: 切换到 Gitee
- **状态**: ✅ 已解决

### 3. ZFS ACL 容器隔离
- **问题**: 容器内 ACL 匹配失败，无法访问 /vol1/1000
- **影响**: 无法直接读取 fpk 源文件
- **解决方案**: 用户复制文件到可访问目录
- **状态**: ✅ 已解决

## 文件清单

```
DeepSeekHarness-NAS/
├── README.md           # 项目说明文档
├── upload.sh           # GitHub/Gitee 上传脚本
├── DEVELOPMENT.md      # 本文件（开发进展记录）
├── syno-spk/          # 群晖 spk 包结构
│   ├── info           # 套件元数据
│   └── scripts/
│       ├── upstream   # 安装/启动脚本
│       └── downstream # 卸载脚本
└── deepseek-harness_*.fpk  # 飞牛插件包（大文件，需手动上传）
```

## 下一步计划

### 短期（本周）
1. 手动上传 fpk 到 Gitee（通过网页或配置 LFS）
2. 完善 spk info 文件的 checksum 和 size
3. 准备图标资源（banner/logo）

### 中期（下周）
1. 在群晖测试环境部署 spk
2. 验证模型管理界面可用性
3. 优化端口配置（3080 默认）

### 长期
1. 支持 ARM 架构（arm64）
2. 集成群晖原生通知系统
3. 添加自动更新机制

## 联系人
- 开发者: Fluquor_Myosotis
- Gitee: https://gitee.com/Fluquor_Myosotis
- 原始项目: https://github.com/deepseek-ai/deepseek-harness

---
*最后更新: 2026-08-17*

## LFS 配置记录 (2026-08-17)

### 配置过程
1. 安装 git-lfs: `apt-get install git-lfs` 或手动下载
2. 初始化: `git lfs install`
3. 跟踪 fpk: `git lfs track '*.fpk'`
4. 提交: `git add -A && git commit -m "feat: add fpk package"`

### 遇到的问题
- git 缺少 `remote-https` 支持，无法 `git push`
- Gitee LFS API 需要完整的 git HTTPS 能力
- 容器环境限制导致无法直接推送

### 解决方案
- 本地 LFS 配置完整，文件已转换
- 需手动上传或在使用 git 的机器上推送
- 所有开发文档已保留，可交接

### LFS 对象信息
- OID: `7a7c26a4afd62ba5990e4ba2c147936f55688f6d2c50e14900be79ca95d1329b`
- Size: 112,744,679 bytes (108 MB)
- File: `deepseek-harness_2026.08.17_x86.fpk`
