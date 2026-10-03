# DSH 插件安装诊断脚本

用于诊断和修复 pnpm store 权限问题，支持插件安装。

## 脚本列表

| 脚本 | 用途 | 用法 |
|------|------|------|
| `test-pnpm-store-fix.sh` | 诊断 pnpm store 权限 | `bash test-pnpm-store-fix.sh [--fix]` |
| `setup-pnpm-store.sh` | 配置替代 pnpm store 路径 | `bash setup-pnpm-store.sh [--apply]` |
| `dsh-plugin-install-fix.sh` | 完整插件安装修复方案 | `bash dsh-plugin-install-fix.sh <plugin> [--install]` |
| `test-sandbox-fix.sh` | 沙盒限制诊断 | `bash test-sandbox-fix.sh` |
| `final-install-test.sh` | 最终安装测试 | `bash final-install-test.sh` |

## 快速开始

```bash
# 1. 诊断问题
bash scripts/diagnose/test-sandbox-fix.sh

# 2. 查看安装修复方案
bash scripts/diagnose/dsh-plugin-install-fix.sh dsh-edit-diff

# 3. 执行自动修复（需要 root 权限）
bash scripts/diagnose/dsh-plugin-install-fix.sh dsh-edit-diff --install
```

## 问题原因

pnpm store 位于 `/vol2/1000/DeepSeek Harness/.pnpm-store/`，受 DSH 沙盒限制无法写入。
工作区目录（`工作区/DeepSeekHarness-NAS`）可正常读写。

## 解决方案

1. **修改 DSH 沙盒配置** - 允许写入 pnpm store 路径
2. **迁移 pnpm store** - 移到工作区内（如 `工作区/.pnpm-store`）
3. **联系管理员** - 调整 profile 目录的沙盒规则
