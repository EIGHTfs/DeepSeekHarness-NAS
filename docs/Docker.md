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

## 2. 构建

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

改三处即可：镜像名、`PUID/PGID`、宿主目录。访问 `http://<宿主IP>:3080/`。

## 4. 工作区怎么接

三件事同时成立：

| 机制 | 做法 | 作用 |
|---|---|---|
| 数据 | `-v /volume1/docker/dsh/data:/data` | 配置/会话/插件；bind 挂载，File Station 可见、能直接备份 |
| 同路径挂载 | `-v /volume1/projects:/volume1/projects` | 会话记录里的绝对路径与裸机一致，跨部署迁移不用改写 |
| 别名清单 | `-v ./workspaces.json:/etc/dsh/workspaces.json:ro` | entrypoint 在 `/workspace/<名>` 建软链，给人短入口 |

清单格式：

```json
{"workspaces": [{"name": "projects", "path": "/volume1/projects"}]}
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
| DSM 的 ACL 在容器内不可见 | 容器只看 Linux 权限位；两套权限模型要各自设对 |

## 6. 已知限制

| 限制 | 说明 |
|---|---|
| 无法预设「默认工作区」 | `defaultWorkspaceId` 是 DSH 内部注册表字段，无配置入口；首次在 UI 选一次即可（会持久化进数据目录） |
| 非 Linux 宿主 | Docker Desktop（macOS/Windows）无法同路径挂载，且 inotify 不可靠，文件监视类功能会异常 |
| 反代与门户 | 容器内保留套件那层（token 门户 / cookie / 入口收敛）；要 HTTPS 就在宿主再加一层 Caddy/Traefik 指向 3080 |
| 公网入口 | 经隧道/公网进来时来源非私网，套件那层「局域网硬闸」会拦，需要放行开关（尚未实现） |

## 7. 升级

```bash
docker compose pull && docker compose up -d
```

`PKG_VERSION=current` 让数据目录不变；旧镜像的容器数据仍在同一 `/data` 下，无需迁移脚本。

## 8. 排错

| 现象 | 检查 |
|---|---|
| 容器起不来、日志 `EADDRINUSE` | 宿主上是否有裸机版 DSH 占着 30800/30801；容器版只暴露 30800，先把宿主那层停掉 |
| 页面能开但插件装不上 | `PUID/PGID` 是否与 `/data` 属主一致；`/data` 是否落在 CIFS 共享上 |
| `/workspace` 里没有别名 | 看 `docker logs dsh` 里 `⚠ 跳过工作区` 那一行，通常是 `path` 没按同路径挂载 |
| 文件属主变成 root | 用了 root 跑容器，或没传 `PUID/PGID` |
