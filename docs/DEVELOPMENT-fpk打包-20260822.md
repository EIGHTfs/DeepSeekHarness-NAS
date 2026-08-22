# fpk 打包留痕：DeepSeek Harness 0.1.1-rc.2（2026-08-22）

> 记录：基于 deepseek-harness-rc7（0.1.0-rc.7，成功安装）为基底，diff 改造为 0.1.1-rc.2。

## 一、变更清单（全部为 diff 式改动，非重写）

### 1. cmd/main（rc7 → 0.1.1，仅 1 处）

```diff
3c3
< APPNAME="deepseek-harness-rc7"
---
> APPNAME="deepseek-harness-0.1.1"
```

（其余逻辑与 rc7 完全一致：start/stop/status/restart → `bin/runner.js` 启动）

### 2. cmd/common（仅 1 处）

```diff
13c13
<     TRIM_APPNAME="deepseek-harness-rc7"
---
>     TRIM_APPNAME="deepseek-harness-0.1.1"
```

### 3. cmd/service-setup（仅 2 处）

```diff
3,4c3,4
< LOG_FILE="${TRIM_PKGVAR}/deepseek-harness.log"
< PID_FILE="${TRIM_PKGVAR}/deepseek-harness.pid"
---
> LOG_FILE="${TRIM_PKGVAR}/deepseek-harness-0.1.1.log"
> PID_FILE="${TRIM_PKGVAR}/deepseek-harness-0.1.1.pid"
```

### 4. bin/runner.js（仅端口，4 处）

```diff
3,4c3,4
<  * 1. 负责启动上游 dsh web (127.0.0.1:3191)
<  * 2. 负责启动局域网透明反向代理 (0.0.0.0:3190 -> 127.0.0.1:3191)
---
>  * 1. 负责启动上游 dsh web (127.0.0.1:3202)
>  * 2. 负责启动局域网透明反向代理 (0.0.0.0:3201 -> 127.0.0.1:3202)
20,21c20,21
< const PROXY_PORT = parseInt(process.env.PORT || '3190', 10);
< const DSH_PORT = 3191;
---
> const PROXY_PORT = parseInt(process.env.PORT || '3201', 10);
> const DSH_PORT = 3202;
233c233
< // 创建透明反代服务 (0.0.0.0:3190)
---
> // 创建透明反代服务 (0.0.0.0:3201)
```

### 5. manifest（appname/version/端口/desc）

```diff
1,2c1,2
< appname         = deepseek-harness-rc7
< version         = 0.1.0-rc.7.20260820b
---
> appname         = deepseek-harness-0.1.1
> version         = 0.1.1-rc.2
8c8,9
< distributor_url = https://github.com/deepseek-ai/deepseek-harness
---
> distributor_url = https://github.com/EIGHTfs/DeepSeekHarness-NAS
> os_min_version  = 1.1.0
10,11c11,12
< desktop_applaunchname = deepseek-harness-rc7.Application
< service_port    = 3190
---
> desktop_applaunchname = deepseek-harness-0.1.1.Application
> service_port    = 3201
14c15,17
< desc            = DeepSeek AI 官方开源 Agent Harness（智能体框架），飞牛 fnOS 原生应用。支持多模型、多通道及 Web UI 管理。
---
> install_type    =
> desc            = DeepSeek AI 官方开源的 Agent Harness（智能体框架），飞牛 fnOS 原生应用。支持多模型（DeepSeek 官方 + 自定义 OpenAI 兼容端点）、多通道及 Web UI 管理，内置透明反向代理与局域网访问解锁补丁。
> changelog       = v0.1.1（内嵌 dsh 0.1.1-rc.2）：升级至官方最新 dsh 版本；内置完整局域网解锁补丁（模型目录/工作区目录在局域网 HTTP 下正常，不再报 403 / crypto.randomUUID 错误）；独立包名 deepseek-harness-0.1.1，不覆盖已装实例。
17d19
< checksum        = 3857fa78a9df6953c0c7af598e20fb9e
```

### 6. app/package.json（dsh 依赖版本）

```diff
-  "version": "1.0.0"          # 旧模板
+  "version": "0.1.1-rc.2"
-  "@deepseek-ai/dsh": "0.1.0-rc.7"
+  "@deepseek-ai/dsh": "0.1.1-rc.2"
```

## 二、版本统一（用户要求：整个包版本字段全改官方版本）

- manifest `version = 0.1.1-rc.2`
- app/package.json `version = 0.1.1-rc.2` + dependencies `0.1.1-rc.2`
- 内嵌 dsh package.json `version = 0.1.1-rc.2`
- 对外命名（文件名/README）用 `0.1.1`（省略 rc）

## 三、官方 CLI 安装排查

```bash
appcenter-cli install-fpk <file.fpk>   # root，96M 装 1-2 分钟
appcenter-cli list | grep <app>
appcenter-cli start/status/check <app>
```

坑：① 安装中断残留 → `rm -rf /var/apps/<app> /vol1/@appcenter/<app>` 重装 ② cmd 权限 755 + 属主应用用户 ③ 启动失败看 `/vol1/@appdata/<app>/info.log` ④ 启动链路 = cmd/main → bin/runner.js（install_callback 空壳不部署应用体）

## 四、状态

- 骨架已按上述 diff 改造完成
- 待：重新 `fnpack build` → 卸载旧 0.1.1 → 重装 → 验证 3201/3202
