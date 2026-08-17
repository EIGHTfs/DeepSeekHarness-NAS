# GitHub 提交指南

由于容器内 git 不支持 HTTPS，无法直接推送。请按以下步骤在本地机器上完成提交：

## 步骤 1：创建 GitHub 仓库

1. 打开 https://github.com/new
2. 仓库名：`DeepSeekHarness-NAS`
3. 设置为 **Public**（或 Private）
4. 勾选 "Add a README file"
5. 点击 "Create repository"

## 步骤 2：克隆并推送

```bash
# 克隆仓库
git clone https://github.com/Fluquor_Myosotis/DeepSeekHarness-NAS.git
cd DeepSeekHarness-NAS

# 复制项目文件（从容器内拷贝到本地后）
# 参考下方的文件清单

# 添加所有文件
git add .

# 提交
git commit -m "feat: initial commit - DeepSeekHarness-NAS for fnOS and Synology DSM"

# 推送到 GitHub
git push -u origin main
```

## 步骤 3：上传大文件（fpk/spk）

由于 fpk (108MB) 和 spk (109MB) 较大，建议使用 Git LFS：

```bash
# 安装 Git LFS
git lfs install

# 跟踪大文件
git lfs track "*.fpk"
git lfs track "*.spk"

# 重新提交
git add .gitattributes
git add deepseek-harness_*.fpk
git add DeepSeekHarness-x438-*.spk
git commit -m "feat: add fpk and spk packages"
git push
```

或者直接在 GitHub 网页上传（单次最大 100MB，超过需用 LFS）：
1. 打开仓库页面
2. 点击 "Add file" → "Upload files"
3. 拖拽 .fpk 和 .spk 文件
4. 提交更改

## 文件清单

需要提交到 GitHub 的文件：

```
DeepSeekHarness-NAS/
├── README.md                      # ✅ 项目说明（已写）
├── CHANGELOG.md                   # ✅ 变更日志
├── RELEASE-NOTES.md               # ✅ 版本说明
├── DEVELOPMENT.md                 # ✅ 开发记录
├── FINAL-SUMMARY.md              # ✅ 项目总结
├── QUICKSTART.md                 # ✅ 快速上手
├── syno-install-guide.md         # ✅ 群晖安装指南
├── .gitignore                    # ✅ Git 忽略规则
├── .gitattributes                # ✅ LFS 配置
├── upload.sh                     # ✅ 上传脚本
├── spk/                          # ✅ 群晖 spk 源码
│   ├── INFO
│   ├── scripts/
│   │   ├── installer
│   │   └── start-stop-status
│   ├── conf/
│   │   ├── privilege
│   │   └── resource
│   └── ui/
│       └── config
├── DeepSeekHarness-x438-0.1.0-6.spk    # ⏳ 群晖套件包 (109MB)
└── deepseek-harness_2026.08.17_x86.fpk # ⏳ 飞牛插件包 (108MB)
```

## 从容器拷贝文件

如果在 Docker 容器内，可以用以下方式把文件拷到主机：

```bash
# 从容器拷贝到主机（需要在能访问 /vol1/ 的机器上执行）
docker cp <container_id>:/vol1/@appshare/DeepSeekHarness/workspace/DeepSeekHarness-NAS /tmp/DeepSeekHarness-NAS
```

## GitHub 仓库地址

```
https://github.com/Fluquor_Myosotis/DeepSeekHarness-NAS
```
