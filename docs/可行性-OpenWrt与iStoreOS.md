# 可行性：OpenWrt / iStoreOS 打包支持

> 结论先行：**能做，但不是 spk/fpk 那套体系**。OpenWrt 系用 opkg（`ipk`），且 iStoreOS 当前基线正是 OpenWrt 24.10 —— 恰好是仍用 `ipk` 的那一代。技术上最大的障碍（musl libc）有官方现成解，真正的成本在「体积」和「init/UI 体系差异」。

## 1. 平台基线（实测，2026-11-14）

| 事实 | 证据 |
|---|---|
| OpenWrt 24.10.x 用 **ipk** | `downloads.openwrt.org/releases/24.10.8/targets/x86/64/packages/` 下是 `Packages` + `*_x86_64.ipk` |
| OpenWrt 25.12.x 已切 **apk** | 同路径 `25.12.6/` 下全是 `*.apk`（Alpine 格式），无 `Packages` 索引 |
| **iStoreOS 基线 = OpenWrt 24.10** | 官方仓库 `https://github.com/istoreos/istoreos` 自述「目前活跃的分支是 istoreos-24.10」 |
| iStore 软件中心 = 标准 OpenWrt 包机制 | 官方仓库 `https://github.com/istoreos/istore` 自述「OpenWrt 标准的软件中心，纯脚本实现，只依赖 OpenWrt 标准组件」 |

含义：**先按 `ipk` 做**（iStoreOS 与 24.10 系 OpenWrt 通吃）；等 iStoreOS 升级到 25.12 基线再补 `apk`。

## 2. 我们这个包的现状（实测）

| 项 | 实测值 | 对移植的含义 |
|---|---|---|
| node 二进制 | 含 `ld-linux-` 与 `GLIBC_2.x` 符号（glibc 版） | OpenWrt 默认 musl → **直接跑不了** |
| 除 node 外的 ELF 二进制 | **0 个**（全树扫过，只有 JS/sh/md） | 关键有利事实：**只要换掉 node 就能跑**，不涉及其他原生依赖 |
| 原生模块（`*.node`） | **0 个** | 同上，无 ABI 雷区 |
| 未压缩体积 | ≈740 MB（node_modules 355 + packages 227 + bin 122 + pnpm 21 + apps 14） | 软路由 `/overlay` 常 1~4 GB → 需裁剪或外置；spk 压缩后仅 165 MB，说明压缩比很高但**安装后仍要占满这份体积** |

## 3. musl 版 Node 有官方现成构建（最大的技术障碍已被消除）

Node 官方在 `unofficial-builds` 提供 musl 构建，实测存在：

```
https://unofficial-builds.nodejs.org/download/release/v24.22.2/
  node-v24.22.2-linux-x64-musl.tar.xz      33.4 MB
  node-v24.22.2-linux-arm64-musl.tar.xz    32.9 MB
（另有 glibc-217 变体，供老 glibc 系统用）
```

所以不需要自己交叉编译 Node，也不需要 Alpine 的 Node 包 —— 用官方 musl 构建替换 `target/bin/node` 即可。

## 4. 平台差异清单（需要动的代码）

| 项 | 群晖/飞牛现状 | OpenWrt / iStoreOS | 处理 |
|---|---|---|---|
| 包格式 | spk / fpk | **ipk**（24.10 系）；25.12 起 apk | 新增打包脚本；`ipk` 可用 `ipkg-build` 或手工 `tar` 组装 |
| 服务管理 | systemd unit（`pkg-<包>.service`） | **procd**（`/etc/init.d/<name>` + `procd_open_instance`） | 新写 init 脚本；`start.sh` 里的启停逻辑可复用，替换外层 |
| 入口 | 套件中心图标 + `ui/config` | 无套件中心；LuCI 页面或直接端口 | 最省事：只提供端口 + 文档；要做体验则写 LuCI 页面 |
| 运行用户 | `run-as: package` 套件用户 | 基本 root 单用户 | 需重审 `start.sh` 里所有 chown/属主假设 |
| libc | glibc | musl | 换 musl 版 node（见上） |
| 存储 | 卷（容量大） | `/overlay` 常 1~4 GB | 依赖现有裁剪（`build/prune-target.sh`）把体积压下来 |
| 端口/防火墙 | 平台已放行反代端口 | 需 `uci` 放行或提示用户在 LuCI 开端口 | init 脚本里加 `uci` 规则或文档说明 |

## 5. 三条路线与工作量

| 路线 | 需要产出 | 工作量 | 我们的增量价值 | 结论 |
|---|---|---|---|---|
| **A. Docker 镜像** | `Dockerfile` + CI 出镜像 + 文档 | 小 | **很低**：容器里「内置 Node / 自启守护 / 套件中心 / 版本隔离 / 产物自检」全部不再需要，只剩「反代那一层 + 几个启动参数」，而这两样第三方镜像已做成 | **不做** |
| **B. ipk + musl node** | `pack-ipk.sh`、procd init、musl node 获取、依赖声明、CI job | 中 | 中：只有「装成系统服务、要包管理器集成」时才需要 | 需要时再做 |
| **C. tar.gz + 安装脚本** | 打包脚本 + 安装卸载脚本 + procd init | 中小 | 中：无包管理器也不想要 Docker 的设备 | 需要时再做 |

**结论：Docker 不做。** 容器里直接用官方镜像 `npx @deepseek-ai/dsh` 就能跑，我们那层「内置运行时 + 平台集成 + 数据隔离 + 产物自检」在容器场景里全部失去意义；真正剩下的只有反代与启动参数，而这两样第三方镜像已经实现得够用（下节对比）。同时要注意：**「npx 就够」只对本地或 host 网络成立** —— DSH 默认只绑回环、配置平面 loopback-only，对外暴露仍会撞信任校验（Host/Origin、`crypto.randomUUID`），所以容器用户迟早要补一层反代。

### 5.1 第三方 Docker 镜像的对外访问方案对比（实测源码）

同一件事（让容器外的人安全地用上 DSH），三种做法差异很大。下表取自各自仓库的实际实现，不是宣传口径：

| 维度 | 本项目（套件） | runzhliu（★172，MIT） | solidlime（★0） | gehennawu（★4，MIT） |
|---|---|---|---|---|
| DSH 监听 | 127.0.0.1 | 127.0.0.1（patch 里写死） | **0.0.0.0** | 127.0.0.1 |
| 对外暴露方式 | 自研反代（门户端口） | 入口脚本做薄中继；默认只发布到宿主回环，LAN 走可选的 `compose.lan.yaml` 网关 | 容器端口直接映射 | 反代/网关 + authelia 认证 |
| 认证 | 启动 token 换签名 cookie + 局域网硬闸 | launch token + 签名 cookie；LAN 网关再叠 Basic Auth | 无（依赖端口映射边界） | authelia 托管 |
| Host/Origin | 反代改写 Origin 为回环 origin 后转发 | **不改写**：网关保留 Host，由 DSH 自己的 Host/Origin 校验把关 | 未见处理 | `trusted-host` 白名单 |
| HTTPS | 无（明文 HTTP） | 有（Caddy 终止 TLS，仅 LAN 覆盖层） | 无 | 有（authelia 侧） |
| 静态资源放行 | 有（否则 favicon 被 302 成 HTML） | 不涉及（无这层） | 不涉及 | 不涉及 |
| 容器页 | 有（iframe 外壳端口） | 有 noVNC 桌面（另一用途：浏览器接管） | 无 | 无 |
| 实现体量 | 反代逻辑内嵌在 2000+ 行的启动脚本里 | 一个 `.cjs` 中继 + 一份 Caddy 配置 | Dockerfile + entrypoint 极简 | 完整 authelia 栈 |

三点值得吸收：

1. **「默认只绑宿主回环、LAN 访问作为显式 opt-in」** 是更安全的默认。我们的反代默认监听全网，靠内部硬闸兜底——功能等价，但默认姿态偏激进。
2. **用现成组件做认证与 TLS**（Caddy / authelia）比自己写反代认证薄得多；我们自研的好处是功能面全（token 门户、静态资源放行、容器页），代价是维护成本与「没有 HTTPS」这个短板。
3. **把「不要直接把端口暴露到 LAN」写成明文警告**放进 README。我们的等价约束目前在文档里是靠行为说明的，没有这么醒目。

## 6. 尚未验证的项（诚实标注）

1. musl 版 node 在真实 OpenWrt/iStoreOS 上的运行情况 —— 未实测，只在文件层面确认了「无原生模块」这个有利前提。
2. iStoreOS 是否默认内置 Docker、以及 Docker 的存储驱动/可用空间 —— 未核实（官方仓库只确认基线版本）。
3. iStore 应用上架的具体规范（元数据格式、审核流程）—— 未细看 `istoreos/istore` 的实现。
4. `ipk` 的依赖声明需要哪些（musl、libstdc++、zlib 等）—— 需在目标固件上 `ldd` 实测。
5. OpenWrt 的 `procd` 与现有 `start.sh` 的进程模型能否直接对接（尤其「父进程守护 + 子进程」结构）—— 需实机验证。

## 7. 建议的最小验证（成本最低、信息量最大）

在任意一台 x86_64 的 OpenWrt 24.10 / iStoreOS 上做四步，就能把上面 5 个未验证项砍掉大半：

```bash
# 1) 换 musl node
curl -LO https://unofficial-builds.nodejs.org/download/release/v24.22.2/node-v24.22.2-linux-x64-musl.tar.xz
tar -xJf node-v24.22.2-linux-x64-musl.tar.xz
./node-v24.22.2-linux-x64-musl/bin/node -v      # 期望 v24.22.2

# 2) 把现有 target 解到 /opt 试跑（不带 systemd，直接前台）
#    重点看：能否加载模块、能否绑端口、日志与权限是否报错
cd <解开的 target> && ./bin/node --version && ./bin/dsh --version

# 3) 用 musl node 起真服务（等价 CI 里 start.sh 的核心动作）
<musl-node> apps/cli/lib/bin.js web --host 127.0.0.1 --port 3080 --no-open

# 4) 记录三件事：内存峰值、/overlay 占用、缺哪些共享库
```

这四步跑通，路线 B/C 才值得投入；跑不通就要先解决共享库或裁剪问题，再谈打包。

## 8. 相关

- 现有打包规范：[打包规范](打包规范.md)
- 构建与发布流程：[构建与发布指南](构建与发布指南.md)
- 群晖侧资源限制（换平台后不再适用，供参考）：[群晖资源限制](群晖资源限制.md)
