# 可行性：OpenWrt / iStoreOS 打包支持

结论：能做，但不是 spk/fpk 那套体系。OpenWrt 系用 opkg（`ipk`），iStoreOS 当前基线是 OpenWrt 24.10，正好是仍用 `ipk` 的一代；最大技术障碍（musl libc）有官方现成解，成本在体积与 init/UI 差异。

## 1. 平台基线

| 事实 | 证据 |
|---|---|
| OpenWrt 24.10.x 用 ipk | `downloads.openwrt.org/releases/24.10.8/targets/x86/64/packages/` 下是 `Packages` + `*_x86_64.ipk` |
| OpenWrt 25.12.x 已切 apk | 同路径 `25.12.6/` 下全是 `*.apk`，无 `Packages` 索引 |
| iStoreOS 基线 = OpenWrt 24.10 | `github.com/istoreos/istoreos` 自述活跃分支为 istoreos-24.10 |
| iStore 软件中心 = 标准 OpenWrt 包机制 | `github.com/istoreos/istore` 自述为纯脚本实现的 OpenWrt 标准软件中心 |

因此先按 `ipk` 做（iStoreOS 与 24.10 系通吃）；等 iStoreOS 升到 25.12 基线再补 `apk`。

## 2. 本包现状

| 项 | 实测值 | 对移植的含义 |
|---|---|---|
| node 二进制 | 含 `ld-linux-` 与 `GLIBC_2.x`（glibc 版） | OpenWrt 默认 musl，直接跑不了 |
| 除 node 外的 ELF | 0 个（全树只有 JS/sh/md） | 只要换掉 node 就能跑 |
| 原生模块 `*.node` | 0 个 | 无 ABI 雷区 |
| 未压缩体积 | 约 740 MB（node_modules 355 + packages 227 + bin 122 + pnpm 21 + apps 14） | 软路由 `/overlay` 常 1~4 GB，需裁剪或外置 |

## 3. musl 版 Node 有官方构建

Node 官方 `unofficial-builds` 提供 musl 构建：

```
https://unofficial-builds.nodejs.org/download/release/<版本>/
  node-<版本>-linux-x64-musl.tar.xz
  node-<版本>-linux-arm64-musl.tar.xz
（另有 glibc-217 变体，供老 glibc 系统）
```

不需要交叉编译，也不需要 Alpine 的 Node 包——用官方 musl 构建替换 `target/bin/node` 即可。

## 4. 平台差异清单

| 项 | 群晖/飞牛 | OpenWrt / iStoreOS | 处理 |
|---|---|---|---|
| 包格式 | spk / fpk | ipk（24.10 系）；25.12 起 apk | 新增打包脚本；`ipkg-build` 或手工 tar |
| 服务管理 | systemd unit | procd（`/etc/init.d/<name>`） | 新写 init；`start.sh` 启停可复用，替换外层 |
| 入口 | 套件中心图标 + `ui/config` | 无套件中心 | 最省事只给端口 + 文档；要体验则写 LuCI 页 |
| 运行用户 | run-as package | 基本 root 单用户 | 重审 `start.sh` 所有 chown/属主假设 |
| libc | glibc | musl | 换 musl 版 node |
| 存储 | 卷 | `/overlay` 常 1~4 GB | 靠现有裁剪压体积 |
| 端口放行 | 平台已放行 | 需 uci 或用户在 LuCI 开 | init 里加 uci 规则或文档说明 |

## 5. 三条路线

| 路线 | 需要产出 | 工作量 | 增量价值 | 结论 |
|---|---|---|---|---|
| A. Docker 镜像 | Dockerfile + CI + 文档 | 小 | 很低：内置运行时、自启守护、版本隔离、产物自检全部失去意义，只剩反代与启动参数 | 不做 |
| B. ipk + musl node | pack-ipk.sh、procd init、依赖声明、CI job | 中 | 中：只有要包管理器集成时才需要 | 需要时再做 |
| C. tar.gz + 安装脚本 | 打包 + 安装卸载脚本 + procd init | 中小 | 中：无包管理器也不要 Docker 的设备 | 需要时再做 |

Docker 不做：容器里直接用官方镜像跑即可。注意「npx 就够」只对本地或 host 网络成立——DSH 默认只绑回环、配置平面 loopback-only，对外暴露会撞 Host/Origin 与 `crypto.randomUUID` 校验，容器用户仍需补一层反代。

### 5.1 第三方 Docker 镜像的对外访问方案对比

同一件事（让容器外安全使用 DSH），三种做法差异很大。下表取自各自仓库实现：

| 维度 | 本项目（套件） | runzhliu | solidlime | gehennawu |
|---|---|---|---|---|
| DSH 监听 | 127.0.0.1 | 127.0.0.1（patch 写死） | 0.0.0.0 | 127.0.0.1 |
| 对外暴露 | 自研反代 | 入口脚本薄中继；默认只发布到宿主回环，LAN 走可选网关 | 容器端口直接映射 | 反代 + authelia |
| 认证 | 启动 token 换签名 cookie + 局域网硬闸 | launch token + 签名 cookie；LAN 叠 Basic Auth | 无 | authelia |
| Host/Origin | 反代改写 Origin 后转发 | 不改写，由 DSH 自校验 | 未见处理 | trusted-host 白名单 |
| HTTPS | 无 | 有（Caddy 终止 TLS） | 无 | 有 |
| 静态资源放行 | 有 | 不涉及 | 不涉及 | 不涉及 |
| 容器页 | 有（iframe 外壳） | noVNC 桌面（另一用途） | 无 | 无 |
| 体量 | 反代内嵌在启动脚本里 | 一个 cjs 中继 + Caddy 配置 | 极简 Dockerfile | 完整 authelia 栈 |

三点可吸收：

1. 「默认只绑宿主回环、LAN 访问作为显式 opt-in」更安全。本项目反代默认监听全网、靠内部硬闸兜底，功能等价但默认姿态更激进。
2. 认证与 TLS 用现成组件（Caddy / authelia）比自己写薄得多；自研的好处是功能面全（token 门户、静态资源放行、容器页），代价是维护成本与没有 HTTPS。
3. 「不要把端口直接暴露到 LAN」应写成明文警告放在显眼处。

## 6. 尚未验证

1. musl 版 node 在真实 OpenWrt/iStoreOS 上的运行情况。
2. iStoreOS 是否默认内置 Docker 及其存储驱动、可用空间。
3. iStore 应用上架规范（元数据格式、审核流程）。
4. ipk 的依赖声明需要哪些（musl、libstdc++、zlib 等），需在目标固件上 ldd 实测。
5. OpenWrt procd 与现有 `start.sh` 进程模型（父进程守护 + 子进程）能否直接对接。

## 7. 最小验证（成本最低、信息量最大）

在任意 x86_64 的 OpenWrt 24.10 / iStoreOS 上做四步，可砍掉大半未验证项：

```bash
# 1) 换 musl node
curl -LO https://unofficial-builds.nodejs.org/download/release/<版本>/node-<版本>-linux-x64-musl.tar.xz
tar -xJf node-<版本>-linux-x64-musl.tar.xz
./node-<版本>-linux-x64-musl/bin/node -v

# 2) 把现有 target 解到 /opt 试跑（不带 systemd，直接前台）
#    重点看：能否加载模块、能否绑端口、日志与权限是否报错
cd <解开的 target> && ./bin/node --version && ./bin/dsh --version

# 3) 用 musl node 起真服务
<musl-node> apps/cli/lib/bin.js web --host 127.0.0.1 --port 3080 --no-open

# 4) 记录三件事：内存峰值、/overlay 占用、缺哪些共享库
```

四步跑通，路线 B/C 才值得投入；跑不通先解决共享库或裁剪，再谈打包。

## 8. 相关

- [打包规范](打包规范.md)
- [构建与发布指南](构建与发布指南.md)
- [群晖资源限制](群晖资源限制.md)
