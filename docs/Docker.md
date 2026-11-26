# Docker 版

把套件产物（`target/`）装进容器跑。**启动逻辑复用套件自带的 `start.sh`**，容器只补三件容器特有的事：属主对齐、工作区别名、`HOME`。

## 1. 与套件版的差别

| 项 | 套件版 | 容器版 |
|---|---|---|
| 启动/停服 | DSM 调 `start.sh` | 同样是 `start.sh`，由 `entrypoint.sh` 转交；容器 stop → `start.sh stop` |
| 端口 | 30800 反代、30801 dsh | 相同；只对外暴露 30800（`-p 3080:30800`） |
| 数据目录 | `var/<版本>/.dsh` | `/data/current/.dsh`（`PKG_VERSION=current`，换镜像数据仍在） |
| 工作区 | 直接选宿主目录 | 宿主目录**同路径挂载** + `/workspace/<名>` 别名 |
| 基础镜像 | — | `debian:12-slim`（随包 node 需要 glibc ≥ 2.28；alpine 不行） |

## 1.1 用官方构建的镜像（推荐）

CI 会按 tag 出多架构镜像（amd64 / arm64 合并为同一 tag），不必自己构建：

```bash
docker pull ghcr.io/eightfs/deepseekharness-nas:0.2.3-alpha.2  # 指定版本（与官方 tag 同名）
docker pull ghcr.io/eightfs/deepseekharness-nas:latest        # 仅正式版会更新 latest
```

预发布版本只打 `0.2.3-alpha.2` 这类版本号与 `alpha` / `beta` / `rc` / `preview` 通道，**不会**覆盖 `latest`（只有正式版才更新 latest）。

首次推送后，GHCR 的包默认是私有的，需要在仓库的 Packages 设置里改为 public，别人才能匿名 `pull`（这一步只能手工点，脚本做不了）。

## 2. 自己构建

```bash
./build/build-common.sh                                     # 产出 build/master-build/<work>/target
docker build -f build/docker/Dockerfile \
    --build-arg TARGET_DIR=build/master-build/<work>/target -t dsh:local .
```

## 3. 运行

```bash
cp build/docker/workspaces.example.json ./workspaces.json   # 按需改名字/路径
docker compose -f build/docker/docker-compose.example.yml up -d
```

改三处即可：镜像名、`PUID/PGID`、宿主目录、以及 `DSH_ADVERTISE_URL`（你实际访问的地址）。

首次认证不需要进容器翻文件：`docker logs <容器>` 里会打印

```
[entrypoint] 首次认证（复制整条到浏览器）：
[entrypoint]   http://<宿主IP>:3080/?token=…
[entrypoint] 认证后直接访问：
[entrypoint]   http://<宿主IP>:3080/
```

应用日志也会跟随到容器 stdout（`docker logs -f <容器>` 即可看运行情况）。

## 4. 工作区怎么接

三件事同时成立：

| 机制 | 做法 | 作用 |
|---|---|---|
| 数据 | `-v <宿主数据目录>:/data` | 配置/会话/插件；bind 挂载，File Station 可见、能直接备份 |
| 同路径挂载 | `-v <宿主工程目录>:<同一条路径>` | 会话记录里的绝对路径与裸机一致，跨部署迁移不用改写 |
| 别名清单 | `-v ./workspaces.json:/etc/dsh/workspaces.json:ro` | entrypoint 在 `/workspace/<名>` 建软链，给人短入口 |

清单格式：

```json
{"workspaces": [{"name": "projects", "path": "<宿主工程目录在容器内的同路径>"}]}
```

`path` 必须是**宿主目录在容器内的同路径**，否则别名指向空处（entrypoint 会在日志里打 `⚠ 跳过工作区 …（宿主目录没有挂进容器）`）。

目录选择器的初始目录取自 `HOME`，entrypoint 把它设成 `/workspace`（可用 `DSH_WORKSPACE_HOME` 覆盖）。

## 5. 权限（最容易出问题的一环）

| 规则 | 原因 |
|---|---|
| `PUID/PGID` 与宿主目录属主一致 | 容器产出的文件属主错了，DSM 上普通用户改不动、删不掉 |
| `UMASK=0002` 组共享 | 同组用户可改，避免「只有容器用户能写」 |
| 不要用 root 跑 | 省事但会留下一堆 root 文件 |
| 数据目录必须本地盘 | CIFS/SMB 共享是 noexec + chmod EPERM，`pnpm` 装插件必失败 |
| 放在 DSM 共享文件夹下要给写权限位 | 共享文件夹根常是 `dr-xr-xr-x`（555），子目录会继承成只读 —— 即使 `chown` 给对了属主，容器内仍写不了日志（实测 `line 176: /data/xxx.log: Permission denied` 并反复重启）。做法：对我们自建的数据/工作区子目录 `chmod u+rwX`，**不要动共享文件夹根**（会清 DSM 的 synoacl ACL）。entrypoint 也会对数据根补 `chmod u+rwx` 兜底 |
| DSM 的 ACL 在容器内不可见 | 容器只看 Linux 权限位；两套权限模型要各自设对 |

## 6. 实测记录（本机真容器验证）

| 项 | 结果 |
|---|---|
| 镜像构建 | `debian:12-slim` + `target/`（821 MB 上下文），构建通过 |
| 启动 | `PUID=1000 PGID=1000` 降权成功；`DSH_HOME=/data/current/.dsh`；日志与 PID 落在 var 根 |
| 别名 | `/workspace/<名> → <宿主同路径>` 建链成功；未挂载的项按预期跳过并提示 |
| 访问 | 首页 302（门户跳转）；`start.sh status` rc=0；`HEALTHCHECK` 转为 `healthy` |
| 属主 | 宿主侧生成文件均为 `1000:1000`（不再出现 root 文件） |
| 重启 | `docker restart` 后 302、同一 `DSH_HOME`、别名仍在（`PKG_VERSION=current` 生效） |

两个在容器里才暴露的问题（已修）：① `/workspace` 由 root 预建并 chown，否则降权后连 `mkdir` 都不允许、别名静默失败；② 非 root 时 `/usr/bin`、`/usr/local/bin` 都不可写，wrapper 写入必须「失败即返回非 0」才能落到兜底路径，且错误要静默（否则每次启动刷两条 Permission denied）。

容器内没有 `dsh` 命令在 PATH 上（wrapper 只能落到 `$HOME/.local/bin`，而 `HOME` 指工作区根）；需要 CLI 时直接调 `/opt/dsh/bin/dsh`。

## 6.1 镜像里不带宿主路径

镜像构建时会清理「随包带进来的运行期残留」（`var/logs`、`var/ports`、`bin/dsh` 陈旧 wrapper —— 实测曾把打包机上一个已删除目录硬编码进 wrapper），并在构建期断言镜像内不出现群晖专属绝对路径（`/volumeN/`）。所以同一个镜像能直接跑在任意 Linux 或 NAS 上，路径差异全部由挂载与 `PKG_VAR` / `DSH_ADVERTISE_URL` 决定。

## 7. 已知限制

| 限制 | 说明 |
|---|---|
| 无法预设「默认工作区」 | `defaultWorkspaceId` 是 DSH 内部注册表字段，无配置入口；首次在 UI 选一次即可（会持久化进数据目录） |
| 非 Linux 宿主 | Docker Desktop（macOS/Windows）无法同路径挂载，且 inotify 不可靠，文件监视类功能会异常 |
| 反代与门户 | 容器内保留套件那层（token 门户 / cookie / 入口收敛）；要 HTTPS 就在宿主再加一层 Caddy/Traefik 指向 3080 |
| 公网入口 | 经隧道/公网进来时来源非私网，套件那层「局域网硬闸」会拦，需要放行开关（尚未实现） |

## 8. 升级

```bash
docker compose pull && docker compose up -d
```

`PKG_VERSION=current` 让数据目录不变；旧镜像的容器数据仍在同一 `/data` 下，无需迁移脚本。

## 9. 排错

| 现象 | 检查 |
|---|---|
| 容器起不来、日志 `EADDRINUSE` | 宿主上是否有裸机版 DSH 占着 30800/30801；容器版只暴露 30800，先把宿主那层停掉 |
| 页面能开但插件装不上 | `PUID/PGID` 是否与 `/data` 属主一致；`/data` 是否落在 CIFS 共享上 |
| `/workspace` 里没有别名 | 看 `docker logs dsh` 里 `⚠ 跳过工作区` 那一行，通常是 `path` 没按同路径挂载 |
| 文件属主变成 root | 用了 root 跑容器，或没传 `PUID/PGID` |
