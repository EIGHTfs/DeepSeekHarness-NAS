# fnpack 使用文档（飞牛 fnOS 官方 fpk 打包工具）

> 官方工具：`/usr/local/bin/fnpack`（dpkg 安装，Version 1.0.0，Maintainer anna <nas@teiron-inc.cn>）
> 本项目副本：`tools/fnpack`
> 2026-08-22 实测记录。配套 skill：`fnos-fpk-package-guide`（权威源 `.dsh/skills/`）。

## 一、命令

```bash
fnpack                      # 版本信息：Version 1.0.0
fnpack build --help         # 打包帮助
fnpack create --help        # 创建项目帮助

# 创建应用项目（native/docker 模板，-w 无浏览器 UI）
fnpack create <appname> [-t native|docker] [-w]

# 打包（-d 指定源目录，默认当前目录）
fnpack build -d <source-dir>
# 输出：<source-dir 名>.fpk（在当前工作目录）
```

## 二、项目结构（fnpack create 官方模板）

```
<appname>/
├── manifest                  # 应用元信息（必填，缺它 build 报 "Required file manifest is missing"）
├── cmd/                      # 生命周期脚本：main / install_init / install_callback / config_init / config_callback / upgrade_* / uninstall_*
├── config/
│   ├── privilege             # {"defaults":{"run-as":"package"}}
│   └── resource              # {"data-share":{"shares":[{"name":"<app>","permission":{"rw":["<app>"]}}]}}
├── app/                      # 应用体 → 打包为 app.tgz，安装后解压到 /vol1/@appcenter/<appname>/
│   └── ui/                   # 前端（app/ui/config 定义 Web UI 入口 .url.<appname>.Application）
├── ICON.PNG                  # 图标 72x72
├── ICON_256.PNG              # 图标 256x256
└── wizard/                   # 安装向导
```

## 三、fpk 成品内部结构

`file x.fpk` → **gzip compressed data**（外层 gzip，与群晖 spk 相反）

```bash
tar -tzf x.fpk   # 列出：app.tgz cmd/ config/ ICON.PNG ICON_256.PNG manifest wizard
```

## 四、manifest 关键字段

```
appname               = <独立名>        # 不覆盖旧版本的关键：appname 不同 = 全新应用
version               = <dsh 版本>      # 如 0.1.1-rc.2
display_name          = DeepSeek Harness
platform              = x86
maintainer            = DeepSeek AI
desktop_uidir         = ui
desktop_applaunchname = <appname>.Application
service_port          = <独立端口>      # 避开已装实例端口
checkport             = false
ctl_stop              = true
source                = thirdparty
wizard_dir            = wizard
checksum              = <app.tgz SHA256>  # fnpack build 自动处理或手动更新
```

## 五、cmd/main 官方模板要点（DeepSeek Harness 适配）

- `$TRIM_PKGVAR/app.pid`：PID 文件
- `$TRIM_PKGVAR/info.log`：日志
- `CMD=""`：填 dsh 启动命令（如 `node --expose-internals dsh web --host 127.0.0.1 --port <PORT> --no-open`）
- `case $1 in start|stop|status)`：start 写 PID、stop 发 TERM→KILL、status 查 PID 存活

## 六、打包 DeepSeek Harness 0.1.1-rc.2（本仓库操作）

1. 准备源目录（参照官方模板）：
   - `manifest`：appname=`deepseek-harness-0.1.1`、version=`0.1.1-rc.2`、service_port=`3201`
   - `cmd/main`：CMD 填 dsh web 启动命令（端口 3201）
   - `app/`：放入应用体（bin/node + lib/pnpm + node_modules/@deepseek-ai/dsh@0.1.1-rc.2 + package.json + ui）
2. 打包：`fnpack build -d <源目录>`
3. 校验：`file <app>.fpk` 应显示 gzip；`tar -tzf` 应含 app.tgz/manifest/cmd
4. 安装测试：飞牛应用中心安装，验证独立端口（3201）可访问

## 七、版本与命名规范（用户铁律）

- fpk manifest version = 官方 dsh 版本（0.1.1-rc.2）
- 对外命名省略 rc（文件名/README 用 0.1.1）
- **独立 appname + 独立端口，绝不替换已装实例**（deepseek-harness 0.1.0-rc.6 @3080、deepseek-harness-rc7 0.1.0-rc.7 @3190）

## 八、相关

- 官方开发者文档：https://developer.fnnas.com/
- skill 权威源：`fnos-fpk-package-guide`（.dsh/skills/）+ 归档 `ai-work-archive/skills/`
- 本仓库源：`fpk-extract/`（旧手打结构，需按官方模板重组）
