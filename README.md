# DeepSeekHarness-NAS

> DeepSeek Harness 的群晖 DSM (.spk) / 飞牛 fnOS (.fpk) 平台适配包

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![DSM](https://img.shields.io/badge/DSM-7.2+-blue)](https://www.synology.com)
[![fnOS](https://img.shields.io/badge/fnOS-1.x+-green)](https://www.flywrc.com)

## 📦 简介

DeepSeek Harness (DSH) 是 DeepSeek AI 官方开源的 Agent 框架，提供 Web UI 管理界面，支持多模型配置、自定义 OpenAI 兼容端点。本仓库提供群晖 DSM (.spk) 与飞牛 fnOS (.fpk) 两个 NAS 平台的适配版本。

当前基线：**dsh 官方 0.1.5-alpha.1**，品牌为 **DeepSeekHarness-NAS**（侧栏 + 浏览器标题）。

### 功能特性

- 🤖 **多模型支持** — DeepSeek 官方模型 + 自定义 OpenAI 兼容端点
- 🔌 **反向代理** — 内置透明反向代理（群晖 30800 → 内部 30801，飞牛 3080 → 内部 3081）
- 🔐 **门户免密登录** — 群晖 Web（DSM 桌面/应用中心）打开套件入口时才携带 token（类似 Iventoy 的「打开」）：带过 token 后，浏览器局域网直接访问即免密；反之从未在网页端带过 token 的直接访问，因没有访问凭证而无法进入
- ⚙️ **Web UI** — 可视化模型管理和配置
- 🛡️ **安全模式** — DSH 启动失败时可一键禁用所有用户插件
- 🚀 **自动隐藏 token** — token 仅短暂出现在 URL 中，dsh 认证后自动收敛为干净地址
- 📝 **代理日志** — 每次请求记录 REQ/RESP 到 `/tmp/dsh-proxy.log`，便于排查

---

## 🚀 编译打包脚本（三脚本分工）

打包拆成三个脚本：**公共预编译只做一次**，SPK / FPK 各自独立打包。

| 脚本 | 职责 | 参数 |
|------|------|------|
| `build/build-common.sh` | **公共**：pnpm install + pnpm build + 黑白名单裁剪 → `target` 整树 + `build-meta.env` | `[SRC] [SKIP_BUILD]` |
| `build/build-spk.sh` | 消费 target → 群晖 `.spk`（端口 30800/30801/30802） | 无 |
| `build/build-fpk.sh` | 消费 target → 飞牛 `.fpk`（端口 3080/3081/3082） | 无 |

```bash
# ① 公共预编译（只跑一次，产出 target；全量约 15-20 分钟）
./build/build-common.sh                        # 全量：扫描源码 → install + build + 裁剪
./build/build-common.sh "" 1                   # 复用已有 target（跳过编译，秒级）

# ② 打包（消费 ① 的 target；无参数，配置读 build-config.yaml）
./build/build-spk.sh                           # → build/staging/<APP_NAME>_x86_64-<SPK版本>.spk
./build/build-fpk.sh                           # → build/staging/<APP_NAME>_x86-<FPK版本>.fpk
```

**参数与配置来源**（已精简，去掉「套件类型 / 套件说明 / 品牌名」三个参数）：

- `SRC` 源码目录：缺省通配扫描 `src/deepseek-ai/*`（不硬编码版本目录名），其次 `build/spk-build/master-build`
- `SKIP_BUILD`：`1` = 复用已有 target（快速重打包），缺省 `0` = 全量构建
- **套件说明 / 品牌名 / 端口**：不走命令行参数，统一读 `build/build-config.yaml`（`defaults` + `spk:` / `fpk:` 段），单一真源
- **版本号**：从源码 `package.json` 自动读取（SPK 取前三位 `0.1.5`，FPK 取完整 `0.1.5-rc.2`）
- **元数据传递**：`build-common.sh` 写 `build/spk-build/build-<版本>/build-meta.env`，两个打包脚本 `source` 它（避免各脚本重复推导版本/名字/描述）
- **环境变量覆盖**：`APP_NAME` / `D_SRC` / `D_BUILD` / `D_STAGING` / `D_ASSETS` / `D_SCRIPTS` 可临时覆盖（换名实验、目录迁移）

> **打包模式**：唯一模式 = 预构建产物包（装完即用，无首启构建）。
> 原「精简包首启构建」逻辑（`ensure_built` + 构建进度占位页）已抽离留档，见 `scripts/first-build-logic.sh`（实际打包不再使用）。

产物统一输出到 `build/staging/`（验证后 `promote-release.sh` 提升到 `release/`，可用 `D_REL=<dir>` 覆盖）。

脚本自动完成（★ 标注执行脚本）：

- **品牌修改** ★`build-common.sh`：locale 内 `DSH Local Build` → `DeepSeekHarness-NAS`（en/zh）+ 构建后 html title 兜底
- **小字完整版本号** ★`build-common.sh`：构建注入 `DSH_CLIENT_VERSION` / `DSH_CLIENT_COMMIT_HASH` / `DSH_CLIENT_TITLE`，界面显示 `<官方版本>-<commit>[-dirty]`（与官方版本同步）
- **SPK 版本号** ★`build-spk.sh` = 官方版本前三位（`0.1.5-alpha.1` → `0.1.5`），无 build 后缀，同版本安装直接覆盖
- **门户资源** ★`build-spk.sh` / `build-fpk.sh`：`ui/` + `spk-templates/ui-config.json` 打进 package.tgz，DSM 安装时自动建 `webman/3rdparty/deepseek-harness-nas` 链接，桌面出现套件图标

### 打包模式：预构建产物包（唯一模式）

| 类型 | 产物文件 | 说明 |
|------|----------|------|
| SPK | `build/staging/<APP_NAME>_x86_64-<SPK版本>.spk` | 预构建产物包：本地构建产物 + 裁剪后 node_modules，装完即用 |
| FPK | `build/staging/<APP_NAME>_x86-<FPK版本>.fpk` | 同上（手动 tar+gzip；app.tgz 与外层均无 `./` 前缀） |

> **裁剪（有依据，非盲删）**：①非 linux-x64 平台变体（darwin/win32/arm/musl/ia32…）；②**devDependencies 及其传递依赖**（清单从根 `package.json` 动态读取，不硬编码——已实测删后 `dsh --version` 与 web HTTP 200 正常）；③claude-agent-sdk/codex（体积大头，明确不需要）；④`packages|apps` 的 src（构建产物在 lib/dist）+ docs/benchmarks/native。保留：`bin/node` + `bin/dsh` + `bin/pnpm` + 随包 pnpm + 各包 lib/dist 产物 + 运行时 node_modules。
>
> **官方依赖表（裁剪依据，来源 dsh 官方 requirements）**：

| 依赖类别 | 具体项 | 是否必需 |
|---|---|---|
| 核心运行时 | Node.js ^22.19.0 或 >=24.0.0 | ✅ 必需 |
| 原生模块 | node-pty, sharp, koffi, esbuild, ripgrep | ✅ 随 npm 安装（**不能裁**，裁剪后已验证完好） |
| 系统库 (Linux) | libc6 (GLIBC)，版本因架构而异 | ✅ 必需 |
| 构建工具 (源码) | pnpm 11.7.0, Git 2.26+, Python 3.10+, C++ 工具链 | 仅源码安装需要（预构建包**不需要**，devDeps 裁剪即依据此条） |
| 可选 | Python 3.10+ (SDK), Docker, 浏览器 | 按需 |

> **验收标准**：安装后能启动、30800 端口可达、门户免密跳转正常、`dsh`/`pnpm` 命令可用。

### 构建产物

| 产物 | 说明 |
|------|------|
| `DeepSeekHarness-x86_64-0.1.5.spk` | 群晖 DSM 套件包（内嵌 node + dsh 0.1.5-alpha.1 全量编译） |

---

## 🚀 安装与访问

### 群晖 DSM（.spk）

```bash
# 前置条件：DSM 7.2+，x86_64 架构（已内置 node，无需额外安装）
# Package Center → 手动安装 → 选择 .spk
```

- Web 入口：DSM 桌面套件图标（网页端打开＝携带 token 的第一步），或访问 `http://<NAS-IP>:30800`
- **门户免密原理（权威设计·禁止改动，参考 SA6400 Iventoy 套件「打开」机制）**：
  1. **群晖 Web 打开才带 token** — DSM 网页（桌面套件图标 / 应用中心）打开套件入口时，浏览器请求才携带 token（同 aria2 / Iventoy 等套件的「打开」方式）；**直接地址栏访问 `http://<NAS-IP>:30800` 不携带 token**；
  2. **带过 token，局域网访问就不用带 token** — 首次经网页端带 token 打开后，浏览器已有访问凭证（会话 cookie），此后直接访问 `http://<NAS-IP>:30800` 即免密；
  3. **反之，Web 没打开过（没带过 token）的直接访问，因为没有带过 token 而无法访问** — 未从网页端建立过凭证的请求不会放行。
  - **实现落点**（`scripts/start.sh.example` 反代段 + 打包脚本 gen_start_sh / gen-portal）：入口收敛 `isDirectAccess()` 判定 + 门户打开时自动 `302 ?token=` 完成认证（认证后 303 收敛干净 URL）；`SameSite=Strict → Lax` 改写解决跨 scheme cookie 丢弃；401 兜底自动重认证。
  - **禁止**：反代不得对「无访问凭证的任意请求」无条件附加 token（会破坏第 3 条，等于开放无鉴权访问）；不得删除 `isDirectAccess()` 入口收敛（否则直连也免密）。
  - **入口收敛判定**（`scripts/start.sh.example`，实测 2026-09-13 VirtualDSM 0.1.5）：只对文档级导航（`Sec-Fetch-Dest: document/iframe/frame`）设卡，页面内 XHR/WS 一律放行；`Sec-Fetch-Site: none` = 地址栏直连 → 403；无 `Sec-Fetch-*` 头（旧 WebView）退化为 Referer 同主机判定；`cross-site` 且异主机 Referer = 外站跳入 → 403；DSM 门户 https:5001 → http:30800（同主机跨 scheme）与 fnOS 门户 iframe 均放行 → 302 带 token；已持 `dsh-auth` cookie → 无条件放行。
  - **验收标准（7 场景实测清单，2026-09-13 193 VirtualDSM 卸载重装全过）**：

| # | 场景 | 请求特征 | 预期 | 实测 |
|---|---|---|---|---|
| 1 | 地址栏直连 | `Sec-Fetch-Site: none` | 403「请从套件图标打开」 | ✅ 403 |
| 2 | DSM 门户打开 | `cross-site` + 同主机 Referer | 302 → `?token=` | ✅ 302 |
| 3 | DSM 门户 Referer 被剥 | `cross-site` 无 Referer | 302 → `?token=` | ✅ 302 |
| 4 | 外站链接跳入 | `cross-site` + 异主机 Referer | 403 | ✅ 403 |
| 5 | 带 token 认证 | `?token=` 访问 | 303 收敛 + 种 `dsh-auth` cookie | ✅ 303+cookie |
| 6 | 认证后直连 | 带 cookie + `none` | 200 免密 | ✅ 200 |
| 7 | HTML polyfill 注入 | 认证后页面 | 含 `randomUUID`/`ownsHost` polyfill | ✅ 10 处 |
- **支持命令行 dsh** — 套件安装/修复后自动建立 `/usr/bin/dsh` 软链，SSH 登录 NAS 后直接敲 `dsh` 即可使用 DSH CLI（无需进入套件目录）。**软链三通道**（实测 DSM 7.4.1 安装时不执行 installer hooks，单靠 postinst 会失效）：
  1. **installer 三 hook** — postinst / prereplace / postreplace / postupgrade 统一走 `setup_pkg_env`（建版本目录 + chown + 建软链），DSM 走脚本管理路径时生效；
  2. **远程安装 root 补建** — `install-remote-spk.sh`（网页安装/修复同源）装完以 root `ln -sf` 补建 `/usr/bin/dsh`（本次实测生效，最可靠通道）；
  3. **start.sh cmd_start 运行时自愈** — 启动时幂等重建软链，fallback 链 `/usr/bin` → `/usr/local/bin` → `$HOME/.local/bin`（先 `mkdir -p` 父目录；DSM 服务以套件用户运行，系统目录不可写时落到套件 HOME）
- 数据目录：`/var/packages/DeepSeekHarness-NAS/target/var/data` 与 `.dsh-home/.dsh`

### 飞牛 fnOS（.fpk）

> 打包使用官方工具 fnpack（`tools/fnpack`，飞牛系统 `/usr/local/bin/fnpack`），见 `docs/DEVELOPMENT-fpk打包-20260822.md`。fpk 应用体与 spk 同源（官方 dsh 版本），门户打开自动带 token，机制与 spk 相同。

---

## 🗂 配置文件设计（远程安装工具）

> 配置设计逻辑（2026-09-11 确立），约束 `install-server.py` / `install-remote-spk.sh` / `build/build-common.sh`+`build-spk.sh`+`build-fpk.sh` 的配置来源，**禁止在代码中写死任何端口或路径**。

### 职责分离：两份配置文件

| 文件 | 位置 | 职责 | 谁写 | 谁读 |
|------|------|------|------|------|
| `install-config.json` | 工作区根 | **连接配置**：目标主机/端口/用户名/密码/包路径 | 网页 `POST /api/save`（install-server.py） | install-server.py、install-remote-spk.sh |
| `build-config.yaml` | `build/`（脚本同级） | **打包与端口权威配置**：defaults/spk/fpk 三段 | 手动维护 | build-spk.sh / build-fpk.sh（各自生成 start.sh 注入本平台端口段）、install-remote-spk.sh（读端口段） |

### install-config.json（网页保存的连接配置）

```json
{
  "host": "192.168.1.100",
  "port": "22",
  "username": "admin",
  "password": "***",
  "system": "dsm",
  "fpk": "/path/to/xxx.fpk",
  "saved_at": "2026-09-10T00:52:05.537Z"
}
```

- 单一来源铁律：**必须在工作区根**（install-remote-spk.sh 读 `$WS_ROOT/install-config.json`），禁止网页把配置写到 scripts/ 等子目录——否则脚本读不到。
- 网页保存时密码留空 = 沿用已保存密码（回显占位「留空沿用」）。
- `system` 字段由网页「探测系统」成功后写入（dsm/fnos），供远程脚本选分支。

### build-config.yaml（端口权威配置，禁止写死）

```yaml
defaults:
  proxy_port: 3080        # fpk 默认段
  dsh_port: 3081
  container_port: 3082
spk:
  proxy_port: 30800       # spk 覆盖（与 fpk 段隔离）
  dsh_port: 30801
  container_port: 30802
fpk:
  # 留空则沿用 defaults（3080 段）
```

- **端口不写死原则**：脚本/网页代码中禁止出现 `30800`/`3080` 等端口字面量；需要端口时调 `read_ports <system>`（install-remote-spk.sh 内嵌，PyYAML 解析 build-config.yaml）按分支读取。
- **端口段隔离**：spk 用 30800 段、fpk 用 3080 段，两者互不冲突，可同时运行（双实例共存）。

### system 推断链（install-remote-spk.sh）

```
system = 参数 > install-config.json 的 system > 包后缀（.fpk→fnos）> dsm（旧默认）
```

### spk/fpk 双分支（install-remote-spk.sh）

| 分支 | 安装 | 卸载 | 检查 |
|------|------|------|------|
| `dsm`（群晖） | `synopkg install` | `synopkg stop/uninstall` + clean-dsm-residue.sh | synopkg 状态 + 门户3文件 |
| `fnos`（飞牛） | `appcenter-cli install-fpk` | `appcenter-cli uninstall` | appcenter-cli 状态 + 端口 |

- 远程检查的端口、临时目录（如 DSM 的 /tmp 是 1.5G tmpfs）、门户路径全部按分支处理，**不共用一套写死值**。

### 端口探测特征（/api/detect 与 detect_remote）

| 系统 | 特征文件（存在即命中） |
|------|------------------------|
| 群晖 DSM | `/etc.defaults/VERSION`、`/usr/syno/bin/synopkg` |
| 飞牛 fnOS | `/usr/trim`、`/usr/local/bin/appcenter-cli`、`/usr/local/bin/fnpack` |

> 飞牛 os-release 伪装成 Debian，不能看 os-release，必须用上述特征文件判定。

---

## ⚙️ 配置自定义 API

1. 打开 Web UI（31800 门户或 `http://<NAS-IP>:30800`）
2. 进入 **设置 → Models**，点击「添加提供方」

配置文件位置：

- 群晖: `/var/packages/deepseek-harness-nas/target/var/data/.dsh/settings.yaml`
- 凭据: `/var/packages/deepseek-harness-nas/target/var/data/.dsh/.credentials.yaml`

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
```

```yaml
API_KEYS:
  DEEPSEEK_API_KEY: "<填入你的API密钥>"  # dsh-skip-sensitive
```

| 提供商 | Base URL | 认证方式 |
|--------|----------|----------|
| DeepSeek 官方 | `https://api.deepseek.com/v1` | Bearer Token |
| Agnes AI | `https://api.agnes-ai.cn/v1` | Bearer Token |
| Ollama 本地 | `http://localhost:11434/v1` | 无需 Key |

---

## 📁 文件结构

工作区按**源码 / 构建物 / 脚本 / 文档 / 发布物**五类归置，根目录只保留打包入口：

```
DeepSeekHarness-NAS/
├── build-common.sh              # 公共预编译脚本（黑白名单筛选 + 源码预编译 → target）
├── build-spk.sh                 # SPK 打包脚本（消费 target → 群晖 .spk）
├── build-fpk.sh                 # FPK 打包脚本（消费 target → 飞牛 .fpk）
├── README.md
├── build/build-config.yaml      # 打包配置（appname/端口/分类目录）
├── src/                         # 【源码】
│   └── deepseek-ai/             #   官方源码快照（打包源）
├── assets/                      # 【临时素材】pnpm-store/cache 等
├── build/                       # 【构建物 + 复用素材】
│   ├── build-common.sh          #   公共预编译（唯一模式 = 预构建产物包）
│   ├── build-spk.sh             #   SPK 打包
│   ├── build-fpk.sh             #   FPK 打包
│   ├── build-config.yaml        #   打包与端口权威配置（defaults/spk/fpk 三段）
│   ├── build-excludes.json      #   tar 排除规则（dist 模式）
│   ├── conf/                    #   权限/资源声明（privilege/resource）
│   ├── ui/images/               #   门户图标
│   ├── PACKAGE_ICON*.PNG        #   套件图标
│   ├── staging/                 #   打包输出暂存区（.spk/.fpk）
│   └── spk-build/               #   SPK 构建中间树（git 黑名单）
├── scripts/                     # 【脚本】
│   ├── start.sh.example         #   SPK/FPK 运行模板母版（唯一权威，打包脚本注入端口生成最终 start.sh）
│   ├── dsh                      #   dsh CLI 包装器（软链解析）
│   ├── pnpm                     #   pnpm 命令包装器（随包 pnpm 软链目标）
│   ├── install-remote-spk.sh    #   远程套件工具（install/uninstall/check 三合一，root 补建软链）
│   ├── install-server.py / -ctl.sh  # 网页安装服务（配置保存+系统探测+远程执行）
│   ├── install.html              #   网页前端（自动判定 SPK/FPK 并直调脚本）
│   ├── clean-dsm-residue.sh     #   DSM 卸载残留清理（远程执行）
│   └── dsh-repair.cjs           #   独立守护
├── docs/                        # 【文档】SPK-FPK 验收清单、打包开发文档
├── tools/pnpm                   #   项目自带 pnpm（构建/随包分发用，不用系统 pnpm）
├── release/                     # 【发布物】只放实测通过的 .spk/.fpk
│   └── DeepSeekHarness-NAS_x86_64-0.1.5.spk / *.fpk
├── tools/                       # 【工具】
│   ├── pnpm/                    #   pnpm 11.7.0（随包分发用）
│   ├── pnpm-bridge.py           #   pnpm 11 配置桥接器
│   └── fnpack                   #   飞牛官方 fpk 打包工具
└── docs/                        # 【文档】
    ├── publish/                 #   发布材料（应用信息汇总 + 截图）
    └── *.md                     #   开发文档
```

### 路径参数化

分类目录全部为变量，三级优先级：**命令行参数 > 环境变量 > config > 默认值**。

```bash
# 环境变量覆盖（优先级最高）
D_REL=/mnt/nas/release ./build/build-fpk.sh           # 发布物输出到别处
D_SRC=/other/src ./build/build-common.sh /other/src   # 换源码树

# config 覆盖（build-config.yaml → defaults.*_dir，相对脚本目录）
#   src_dir / assets_dir / build_dir / release_dir / tools_dir / scripts_dir
```

脚本启动时会自检分类目录并自动创建输出目录，路径写错会立即报错而非静默失败。

---

## 🐛 故障排除

### 浏览器 ERR_TOO_MANY_REDIRECTS

DSM 门户是 https（5001），套件是 http（30800）——**跨 scheme 携带 SameSite=Strict cookie 会被浏览器丢弃**，导致无限 302。SPK 内代理已把 dsh 响应的 `SameSite=Strict` 改写为 `SameSite=Lax` 修复。若仍出现，确认用的是最新 0.1.5.spk。

### DSM 桌面图标不出现 / 门户打不开

**根因：INFO `dsmappname` 与 `ui/config` 键名不一致**。DSM 要求两者逐字匹配，否则桌面图标点不开、套件中心无「打开」按钮。

| 文件 | 字段 | 要求 |
|------|------|------|
| INFO | `dsmappname="SYNO.SDS.XXX.Application"` | 去掉连字符（`DeepSeekHarness-NAS` → `DeepSeekHarnessNAS`） |
| ui/config | `.url."SYNO.SDS.XXX.Application"` | 必须与 INFO dsmappname **逐字一致** |
| ui/config | `protocol` + `port` | DSM 自动拼 NAS 真实 IP（不要用 `url: "http://localhost:..."`） |

**ui/config 正确格式**（DSM 自动拼地址，不写死 localhost/IP）：

```json
{
    ".url": {
        "SYNO.SDS.XXX.Application": {
            "type": "url",
            "protocol": "http",
            "port": "30800",
            "icon": "images/icon_{0}.png",
            "title": "显示名",
            "allUsers": false
        }
    }
}
```

**修复方式**：`scripts/start.sh.spk` 模板的 gen-portal 用 `__APP_ID__`（去连字符）而非 `__APP_NAME__`（带连字符）；打包脚本的 `gen_start_sh()` 通过 sed `__APP_ID__` → `APP_ID` 自动替换。

### synopkg error 263 / 313 安装失败

**263 "failed to create temp dir"**：上次卸载不干净，DSM 包数据库（`/var/cache/synopkg/installed/existence`）残留条目 → synopkg 把新安装当 repair → 找不到旧文件就 263。修复：`scripts/clean-dsm-residue.sh` 全面清理（目录 + systemd + 缓存 + samba + 用户组）。

**313 "failed to revise file attributes"**：SPK 内外层文件权限不对。DSM 要求标准 Unix 权限（目录755，文件644，脚本755），`0707` 权限会被拒。build-spk.sh / build-fpk.sh 已在 tar 前自动修正权限。

### pnpm store 只读分区问题

群晖 `/vol2` 根挂载为只读（ZFS），pnpm 全局 `storeDir` 指向该分区时 `pnpm install`/`pnpm build` 报 EROFS。修复：

- `pnpm install`：`--store-dir=<可写路径>`（CLI 最高优先级）
- `pnpm run build`：`HOME=<可写临时目录>`（绕过只读分区的全局 pnpm 配置）

build-common.sh 已自动处理（`$WS/assets/pnpm-store` + `$WS/assets/tmp-home`）。

### 平台裁剪（原生二进制瘦身）

pnpm 安装时会拉取**所有平台**的原生二进制包（esbuild/rolldown/oxlint/sharp/canvas 等），每个包有20+平台变体，总计 ~1.4GB。build-common.sh 在预编译阶段自动裁剪：

- **保留**：`linux-x64-gnu` / `linux-x64-musl`（NAS 目标平台）
- **删除**：darwin / win32 / linux-arm / linux-ppc / freebsd / android 等全部非 linux-x64 变体
- 裁剪后 .pnpm 从 ~2.3GB 降至 ~1GB

### 大小门禁

SPK 超过 500MB 自动报错退出，防止平台裁剪失败或意外大包（预构建包目标 ~200MB）。

### 端口冲突

默认 30800（代理）/ 30801（dsh）/ 30802（容器）。如需修改，编辑 `scripts/start.sh.spk` 顶部端口变量后重打包。

### 查看代理日志

```bash
tail -f /tmp/dsh-proxy.log   # 每行 REQ/RESP 含 cookie 前缀，可确认 token 跳转链路
```

### 服务状态管理

```bash
sudo synopkg status deepseek-harness-nas
sudo synopkg start deepseek-harness-nas
sudo synopkg stop deepseek-harness-nas
```

---

## 🔄 版本记录

| 版本 | 内嵌 dsh | 说明 |
|------|----------|------|
| 0.1.5 (2026-09-13) | 0.1.5-rc.2 | **入口收敛（门户 token 免密权威实现，实测通过）**：start.sh 反代区分「套件门户打开」与「局域网直连」——套件图标打开（DSM 桌面 https:5001→http:30800 / fnOS 应用 iframe）302 无条件带 token 免密；地址栏直连（`Sec-Fetch-Site: none` / 无 Referer）403 提示「请从套件图标打开」；外站链接跳入（异主机 Referer）403；已持 dsh-auth cookie 直连放行（带过 token 即免密）。SameSite=Strict→Lax 改写保跨 scheme cookie。**产物命名改 `<APP_NAME>_<平台>-<版本>.<spk|fpk>`（去 -dist）**；**GitHub Actions 自动构建**（复用 fetch-dsh-latest.sh 拉官方源，SPK 构建，FPK 分支注释）；**脚本执行位修正**（git 索引 100755）。实测：193 VirtualDSM 卸载重装 0.1.5，7 场景全过（直连 403 / 门户 302 带 token / 认证后直连免密 200） |
| 0.1.5 (2026-09-12) | 0.1.5-rc.2 | **dsh 软链三通道**（installer 三 hook + 远程 root 补建 + start.sh 运行时自愈；实测 DSM 7.4.1 安装不执行 installer hooks，root 补建为可靠通道）；start.sh.spk 母版动态生成（build.sh gen_start_sh 替换端口占位符，含端口等配置）；群晖无 `ss` 改用 `netstat`；installer 补 prereplace/postreplace（替换安装也建软链+版本目录）；网页 repair 远程真清理（传 host/user）；**pnpm 随附 + `/usr/bin/pnpm` 软链**（bin/pnpm 包装器，三通道同 dsh）；**废弃精简/源码包模式，唯一预构建产物包**（删 SLIM 参数；裁剪=平台变体+devDeps 动态清单+claude/codex+src/docs，副本实测 dsh+web 正常，压缩 ~274MB） |
| 0.1.5 (2026-09-11) | 0.1.5-rc.2 | 升级到官方 dsh-v0.1.5-rc.2；门户修复（dsmappname 键名一致 + ui/config 用官方 url 字段）；平台裁剪（自动删除非 linux-x64 原生二进制 ~1.4GB）；pnpm store 只读分区修复（HOME 绕过）；build-excludes.json 外置排除规则；大小门禁 500MB |
| 0.1.5 (2026-09-10) | 0.1.5-alpha.1 | 工作区五类归置（src/assets/scripts/build/docs/release）；分类目录路径参数化（环境变量+config+默认三级）；精简包随附 pnpm + pnpm-bridge；精简包 native 预置跳过编译；首启构建免 git（DSH_CLIENT_COMMIT_HASH 兜底）；四种打包方式矩阵（后废弃精简/源码包模式） |
| 0.1.5 | 0.1.5-alpha.1 | 品牌 DeepSeekHarness-NAS；SPK 版本取官方前三位；DSM 门户免密（自动带 token + SameSite=Lax 修复）；代理日志保留 |
| 0.1.1-2 | 0.1.1-rc.2 | 独立包名 deepseek-harness-nas，局域网解锁补丁 |
| 0.1.0-rc.7 | 0.1.0-rc.7 | 飞牛 fpk rc.7 修复版（DSH_HOME 锁定） |

> **关于 `tools/pnpm`**：内置 pnpm 11.7.0（含 `dist/pnpm.mjs` 约 9.7MB）为**有意随仓库分发**的构建工具——构建与随包分发**一律用项目自带 pnpm**（build-common.sh `PNPM_BIN` 固定指向它，PATH 前置），不用系统 pnpm。预构建包把它打进套件 `pnpm/` 并建 `/usr/bin/pnpm` 软链（`bin/pnpm` 包装器用包内 node 跑 pnpm.mjs），SSH 登录 NAS 直接 `pnpm` 可用。

---

## 📄 许可证

MIT License - Copyright (c) 2026 DeepSeek AI

---

*最后更新: 2026-09-12（唯一预构建产物包模式 + dsh/pnpm 软链三通道 + build-config 权威迁移 build/）*