# FPK 差分报告

## 文件对比

| 文件 | 官方版 | 测试版 | 变更 |
|------|--------|--------|------|
| `manifest` | 722 bytes | 803 bytes | appname/version/port 变更 |
| `cmd/main` | 3823 bytes | 3828 bytes | APPNAME 变量变更 |
| `DeepSeekHarness.sc` | 137 bytes | 137 bytes | 无变更 |
| `ICON.PNG` | 1995 bytes | 1995 bytes | 无变更 |
| `ICON_256.PNG` | 8848 bytes | 8848 bytes | 无变更 |
| `app.tgz` | 113458922 bytes | 113458922 bytes | 相同（未修改） |

## 变更摘要

### 1. manifest
- `appname`: `deepseek-harness` → `deepseek-harness-test`
- `version`: 添加 `-beta` 后缀
- `display_name`: 添加 `(Test)` 标识
- `service_port`: `3080` → `3081`
- `checksum`: 重新计算 SHA256

### 2. cmd/main
- `APPNAME`: `deepseek-harness` → `deepseek-harness-test`

### 3. 其他文件
- 全部保持不变

## 部署建议

### 共存配置
两个版本可以同时安装，互不干扰：

| 版本 | appname | 端口 | 数据目录 |
|------|---------|------|----------|
| 正式版 | deepseek-harness | 3080 | /vol1/@appdata/deepseek-harness |
| 测试版 | deepseek-harness-test | 3081 | /vol1/@appdata/deepseek-harness-test |

### 安装顺序
1. 先安装正式版（端口 3080）
2. 再安装测试版（端口 3081）
3. 通过不同端口访问：
   - 正式版：http://NAS-IP:3080
   - 测试版：http://NAS-IP:3081

### 注意事项
- 两个版本的数据完全隔离
- 配置文件独立：`/vol1/@appdata/deepseek-harness*/.dsh/settings.yaml`
- 测试版可随时卸载，不影响正式版
