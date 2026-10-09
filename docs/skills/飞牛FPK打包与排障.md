# Skill：飞牛 fnOS FPK 打包与排障

> 本文承载 FPK 链路的**解释性内容与排障经验**，全部来自 2026-10-09 的真机实测。
> README 只给"怎么用"，推导过程与现场证据在这里。

## 一、FPK 与 SPK 的关键差异（为什么同一个缺陷只在 FPK 上炸）

两条链路**共用同一个 target**（`build/build-common.sh` 产出），裁剪规则也相同，
但出货形态不同，导致同一缺陷表现完全不同：

| | SPK（群晖） | FPK（飞牛） |
|---|---|---|
| 载荷 | `package.tgz`，**保留软链** | `app.tgz`，**必须删软链** |
| 为什么 | Synology 安装对软链没意见 | fnOS 解压时逐条目设 ACL，软链会让 `acl_get_file failed` |
| 缺包的后果 | 软链完整时往往仍能解析到 → 可能"侥幸能跑" | 缺一个包就是硬缺 → 插件直接 failed to import |

**结论**：凡是在 FPK 上验证过的缺陷，SPK 也要顺带回归一次；反之不成立。

## 二、FPK 安装失败「设置目录权限失败」

- **现象**：`appcenter-cli install-fpk` 报错，前端提示「应用包不符合系统要求」/「设置目录权限失败」。
- **真实报错**（**appcenter 自己的日志**，不在 `/usr/trim/logs`）：
  `/var/log/trim_app_center/error.log`
  ```
  install error appName=DeepSeekHarness-NAS class=install
  error="set app dir permissions failed: installType=volume appname=…: acl_get_file failed"
  ```
- **根因**：`app.tgz` 里 npm/pnpm 生成的软链（实测 5863 条，全是 `node_modules/.pnpm` 的相对链接）
  在打包后成为自引用/损坏链接；fnOS 解压时逐条目设 ACL → 失败。
- **修法**（`build/FPK/pack-fpk.sh` 的 app.tgz 后处理，三步缺一不可）：
  1. 记录全部软链到外层 `links.tar`（只含软链条目，`tar --no-recursion -T`）；
  2. 删除 `app.tgz` 内全部软链；
  3. 所有条目 `uid/gid` 重置为 root，目录 755 / 文件 644（`tar --owner=0 --group=0 --numeric-owner`）。
- ⚠ **不要用文本清单 + 逐行 `ln -s` 还原**：实测 5863 条里会错 542 条（含 `@deepseek-ai/dsh`），
  导致插件 failed to import。安装期必须 `tar -xf links.tar -C <应用体>` 原样解回。

## 三、装成功但「一直启动中」/ 插件 failed to import / 新建会话失败

- **现象**：`appcenter-cli check` 是 Installed，但日志里
  `plugin-manager / otel / schedule / office-to-pdf: failed to import`、
  `tool-schedule never started`，界面"新建会话失败"。
- **两类根因**：
  1. **钩子缺失**：`pack-fpk.sh` 的钩子循环漏了 `install_callback`
     （fnOS 只按官方薄壳结构执行 `cmd/` 下的钩子）→ 安装钩子不执行。
  2. **运行时依赖被裁**：模式 B 是纯白名单裁剪（**刻意不做依赖闭包**，否则 target 会到 5.3G），
     被删掉的运行时传递依赖必须由 `build/fix-runtime-deps.sh` 探测补齐。实测漏掉的是
     `execa → is-plain-obj`、`@js-temporal/polyfill → jsbi`。
- **★ 补包必须放在 `build/build-common.sh` 里（裁剪之后、写 meta 之前）**：
  CI 的打包 job **只有 target artifact，没有构建副本 `$BUILD_SRC`** ✗ ——
  放在 `pack-spk.sh` / `pack-fpk.sh` 里调用，在 CI 里会**静默跳过**
  （日志：`▶ 跳过运行时补包（… BUILD_SRC 不完整）`），等于从未生效。
  放在 `build-common.sh` 时 `$BUILD_SRC` 就在手边，补进的是 `$TARGET`，两个打包器都受益。

## 四、套件图标打开打不开 / URL 不带 token

- **现象**：从飞牛桌面/套件图标打开，浏览器落到 `http://<NAS>:3080/`（不带 token），
  看到「请从套件图标打开」或跳转异常。
- **三条实测事实**：
  1. 应用体 `<应用体>/ui/config` 的 `url` 是**正确**的（`/?token=<当次 token>`）；
  2. fnOS 桌面图标用的是**安装时缓存**的 `/`（门户记录在它的库里，不会实时读 `ui/config`）；
  3. 反代的入口收敛里，`sec-fetch-site: none` 被当成"地址栏直连"证据 ——
     而 **fnOS 套件打开与地址栏直连都会发 `none`，无法区分** → 从套件打开必吃 403。
- **修法**：把「自动带 token」分支**前置**到 403 之前。
  局域网硬闸是最外层边界，因此局域网内 + 无 token + 无 cookie 一律 302 自动登录；
  仅当拿不到 token 时才回落到 403 提示页。
- **验证方法**（不需要真浏览器）：
  ```bash
  # 模拟套件打开：不带 token、不带 cookie、sf=none
  curl -sI -H "Sec-Fetch-Site: none" -H "Sec-Fetch-Dest: document" -H "Accept: text/html" \
       http://<NAS>:3080/          # 期望 302，且 Location 带 token
  curl -sL -c jar -b jar -o /dev/null -w '%{http_code}\n' \
       -H "Sec-Fetch-Site: none" -H "Sec-Fetch-Dest: document" -H "Accept: text/html" \
       http://<NAS>:3080/          # 期望最终 200（跟随时必须带 cookie jar）
  ```
  ⚠ 不带 cookie jar 的 curl 会看到 302/303 自循环 —— 那是 curl 不存 cookie，不是服务问题。

## 五、应用数据目录里凭空多出 `tmp/`

- **现象**：`<PKG_VAR>/<version>/tmp/` 被建出来（里面是 node 的临时文件）。
- **来源**：`start.sh` 顶层曾把 `TMPDIR` 指向 `${PID_DIR}/tmp`（为绕开 fnOS `/tmp` 属 root 不可写）。
- **修法**：优先用平台自带的按应用临时目录 ——
  `$TRIM_PKGTMP` / `/var/apps/<app>/tmp`（实为 `/vol2/@apptemp/<app>`）；
  群晖用 `/var/packages/<app>/tmp`；都没有才回退。
  ⚠ 顶层只**选路径**不建目录（只读子命令 `check` 必须真的只读），建目录留给 `ensure_pid_dirs`。

## 六、排障必备事实（省得到处瞎找）

| 事项 | 位置 / 命令 |
|---|---|
| appcenter 真实报错 | `/var/log/trim_app_center/error.log`、`info.log` ★ |
| 安装命令 | `appcenter-cli install-fpk <包> [-v <卷号>]` |
| 状态/清单 | `appcenter-cli check/status/list <app>` |
| 手动安装开关 | `appcenter-cli manual-install [enable|disable]`（**位置参数**） |
| 应用体 | `/vol2/@appcenter/<app>`（`/var/apps/<app>/target` 是它的软链） |
| 数据目录 | `/vol2/@appdata/<app>/<version>/` |
| 平台临时目录 | `/vol2/@apptemp/<app>`（`/var/apps/<app>/tmp` 指向它） |
| 门户 URL 文件 | `<应用体>/ui/config` 的 `.url.<App>.url` |
| 反代日志 | `<数据目录>/<version>/dsh-proxy.log`（REQ/RESP/DENY 逐条） |
| 卷与 ACL 能力 | `/vol1`=btrfs（无 trimacl）、`/vol2`=zfs（有 `xattr,trimacl`）；默认安装卷=2 |

## 七、出包前必跑的两个守卫

```bash
# 1) 打包不变量（12 项，已登记进 CI）
./scripts/check-packaging-invariants.py

# 2) 与「安装成功过的包」做结构比对（手动指定两个包，spk/fpk 均可）
./scripts/check-package-parity.py <基准包> <候选包>
```
`check-package-parity.py` 会抓：外层条目/钩子缺失、FPK 载荷含软链、
**links.tar / links.txt 里的悬空软链**（即"运行时必缺包"）、manifest 字段差异。
