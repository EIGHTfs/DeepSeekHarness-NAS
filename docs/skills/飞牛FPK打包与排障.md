# Skill：飞牛 fnOS FPK 打包与排障

> 本文承载 FPK 链路的**解释性内容与排障经验**，全部来自 2026-10-09 ~ 10 的真机实测。
> README 只给"怎么用"，推导过程与现场证据在这里。
> **跨链路的开发与编辑规范见 `docs/skills/通用开发规范.md`** —— 那篇讲"怎么不出错"，
> 本文讲"FPK 怎么排障"。本文每条结论都注明证据类型（实测 / 推断），**推断不得当结论用**。

## 一、FPK 与 SPK 的关键差异（为什么同一个缺陷只在 FPK 上炸）

两条链路**共用同一个 target**（`build/build-common.sh` 产出），裁剪规则也相同，
但出货形态不同，导致同一缺陷表现完全不同：

| | SPK（群晖） | FPK（飞牛） |
|---|---|---|
| 载荷 | `package.tgz`，**保留软链** | `app.tgz`，**必须删软链** |
| 为什么 | Synology 安装对软链没意见 | fnOS 解压时逐条目设 ACL，软链会让 `acl_get_file failed` |
| 缺包的后果 | 软链完整时往往仍能解析到 → 可能"侥幸能跑" | 缺一个包就是硬缺 → 插件直接 failed to import |
| 入口/按钮注册 | 由 `INFO`/`conf` 驱动，安装即注册 | 由**应用中心判定启动成功**驱动（见第九节）★ |

**结论**：凡是在 FPK 上验证过的缺陷，SPK 也要顺带回归一次；反之不成立。
另：**SPK 载荷里的悬空软链不影响安装可用**（群晖原样解软链、dev/可选包本就不需要、
运行期还有 `start.sh` 自愈兜底；官方 2.0 基准包自身也有 5638 条同形态链），
故 pairty 工具对此只给**提示**，不做硬判据。

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
- ⚠ **不要依赖 fnOS 解出外层自定义文件**：实测 `links.tar` 在 `/var/apps/<app>/`、
  `/var/apps/<app>/target/`、应用体三处**都不存在** → 该还原机制在飞牛上**实际不生效**，
  真正兜底的是 `start.sh` 的启动期自愈（三层链接重建），见第三节与不变量 [13]。

## 三、装成功但「一直启动中」/ 插件 failed to import / 新建会话失败

- **现象**：`appcenter-cli check` 是 Installed，但日志里
  `plugin-manager / otel / schedule / office-to-pdf: failed to import`、
  `tool-schedule never started`，界面"新建会话失败"。
- **三类根因**（按出现频率）：
  1. **钩子缺失**：`pack-fpk.sh` 的钩子循环漏了 `install_callback`
     （fnOS 只按官方薄壳结构执行 `cmd/` 下的钩子）→ 安装钩子不执行。
  2. **运行时依赖被裁**：模式 B 是纯白名单裁剪（**刻意不做依赖闭包**，否则 target 会到 5.3G），
     被删掉的运行时传递依赖必须由 `build/fix-runtime-deps.sh` 探测补齐。实测漏过
     `execa → is-plain-obj`、`@js-temporal/polyfill → jsbi`、`got@11 → @szmarczak/http-timer`。
  3. **链接层缺失/指错**（2026-10-10 新增）：pnpm 的链接分三层 ——
     ① 顶层 `node_modules/<包名>`、② 提升 `node_modules/.pnpm/node_modules/<包名>`、
     ③ 包内 `.pnpm/<包名>@<版本>/node_modules/<依赖>`。
     实测两类缺陷：
     - **从没补过顶层**（Node 从 `apps/cli/lib/` 往上找，命中的正是顶层）→
       装完 `commander/js-yaml/@deepseek-ai/cordis` 全缺；补 661 条顶层链后应用立刻可用。
     - **只补缺、不纠正已存在的错链** → pnpm 把提升链指向旧版本时永远修不好：
       实测 `execa@10.0.1` 声明 `get-stream ^9.0.1`，而 `.pnpm/node_modules/get-stream`
       指向 `5.2.0`（CJS）→ 报 `Named export 'getStreamAsArray' not found` →
       `plugin-manager` 起不来；只把这一条链改指 9.0.1 后立刻可加载。
- **★ 补包必须放在 `build/build-common.sh` 里（裁剪之后、写 meta 之前）**：
  CI 的打包 job **只有 target artifact，没有构建副本 `$BUILD_SRC`** ✗ ——
  放在 `pack-spk.sh` / `pack-fpk.sh` 里调用，在 CI 里会**静默跳过**
  （日志：`▶ 跳过运行时补包（… BUILD_SRC 不完整）`），等于从未生效。
  放在 `build-common.sh` 时 `$BUILD_SRC` 就在手边，补进的是 `$TARGET`，两个打包器都受益。
- **★ 出货裁剪（模式 B）必须并入 `_autoLearned`**：`learn-prune-whitelist.sh` 学到的包写在
  `_autoLearned`，而模式 B 原先只读 `lockfileDeps + workspaceRuntimeDeps` →
  **学习成果全部落空**（README 却把它写成"强制保留项"）。实测 `@szmarczak/http-timer`
  在 `extra` 与 `_autoLearned` 里都有，唯独不在 `lockfileDeps` → 出货被删 → otel 挂。
  已修（不变量 [19]），白名单 489 → 546 项。

## 四、套件图标打开打不开 / URL 不带 token

> ⚠ **先分清两种现象**（本轮踩过大坑）：
> - **点击后 403 / 跳转异常** → 本节（token 与反代问题）；
> - **「打开」按钮干脆不出现** → **不是本节问题**，是 fnOS 应用中心判定**启动失败**，
>   见 **第九节**（error 10330）。曾把两者混为一谈，反复手工补文件十余次都没用。

- **现象**：从飞牛桌面/套件图标打开，浏览器落到 `http://<NAS>:3080/`（不带 token），
  看到「请从套件图标打开」或跳转异常。
- **三条实测事实**：
  1. 应用体 `<应用体>/ui/config` 的 `url` 必须是**固定 `/`**（写成 `/?token=…` 会让
     fnOS「打开」按钮点不开 —— 实测，勿回退）；
  2. fnOS 桌面图标用的是**安装时缓存**的入口记录（门户记录在它的库里，不会实时读 `ui/config`）；
  3. 反代的入口收敛里，`sec-fetch-site: none` 被当成"地址栏直连"证据 ——
     而 **fnOS 套件打开与地址栏直连都会发 `none`，无法区分** → 从套件打开必吃 403。
- **修法**：把「自动带 token」分支**前置**到 403 之前。
  局域网硬闸是最外层边界，因此局域网内 + 无 token + 无 cookie 一律 302 自动登录；
  仅当拿不到 token 时才回落到 403 提示页。陈旧 token 也要兜底：
  非当次 token → 302 换成当次，否则每次重启应用后套件图标都会带着过期 token 打不开。
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
| **平台判定逻辑（权威）** | `strings /usr/trim/bin/trim_app_center \| grep -iE "desktop_\|applaunch\|privilege"` |
| 平台错误码现场 | `grep -a "start app error" /var/log/trim_app_center/error.log`（含 `error="10330:"` 与 Go 栈） |
| 门户静态路由 | `/usr/trim/nginx/conf/conf.d/trim_app_center.conf`（`/app-center-static/…`）；<br>取图标记录见 `/usr/trim/nginx/logs/access.log` |
| **期望 vs 现实** | `appcenter-cli list` 只表示平台"认为"的状态；真实进程用 `ss -ltnp` + `ps` 交叉验证 |
| 平台 hook 身份 | `config/privilege` 的 `run-as`：`package` = 以包用户跑（写不进 `/var/apps/<app>`，实测 `权限不够`）；`root` = 以 root 跑（1Panel 那种） |
| 生成物自检 | 生成物（`cmd/main`、SPK `scripts/start-stop-status`）里"被调用但未定义的函数"必须为 0（见 9.1 脚本） |

## 七、出包前必跑的两个守卫

```bash
# 1) 打包不变量（21 项，已登记进 CI；每项都做过"故意破坏 → 必须失败"的反向验证）
#    与 FPK 直接相关的关键项：
#      [13] start.sh 含启动期自愈（工作区链接 + links.tar）
#      [15] 门户 url 固定 "/"（写 token 会让「打开」按钮点不开）
#      [17] install_callback 保留 /var/apps/<app>/ui 的尽力而为复制（非必需项，防误删）
#      [18] 修复脚本会【纠正错链】（relink / fixLink），不只补缺
#      [19] 出货裁剪（模式 B）并入 _autoLearned（否则学习成果落空）
#      [20] FPK/SPK 生成的 cmd/main 自带 running_dsh 定义 ★（缺 → 应用中心判启动失败 10330）
#      [21] FPK 生成物用运行时端口变量 ${DSH_PORT:-$FPK_DSH_PORT} ★（用错 → 恒判失败）
./scripts/check-packaging-invariants.py

# 2) 与「安装成功过的包」做结构比对（手动指定两个包，spk/fpk 均可）
./scripts/check-package-parity.py <基准包> <候选包>
```
`check-package-parity.py` 会抓：外层条目/钩子缺失、FPK 载荷含软链、
`links.tar` / `links.txt` 里的悬空软链（即"运行时必缺包"）、manifest 字段差异。
⚠ **该工具的悬空判定只作提示**：SPK 官方基准包自身也有 5638 条同形态链且工作正常；
且工具曾因两处路径归一化 bug（tar 目录条目带结尾斜杠、清单路径带 `./` 前缀）
把官方基准判成"5638 条悬空" —— 见 `docs/skills/通用开发规范.md` 3.3「对照物必须 0 告警」。

## 八、★ 同版本「覆盖安装」不会把新增文件拷进应用体

实测（2026-10-09 ~ 10）：应用已装、再 `install-fpk` **同一个版本号**的包时，fnOS **保留已有的
应用目录**，只做增量 —— 于是"新版本包里多出来的东西"**不会被拷进去**：

| 判据 | 实测结果 |
|---|---|
| 应用体内 `.pnpm` 目录数 | 仍是旧的 383（新包 398）→ 覆盖安装没拷全 |
| 应用体内 `bin/start.sh` | 仍是旧版（`错链纠正` 字样 0 处；新包应有 1 处） |
| `appcenter-cli check` | 仍是 `Installed`（**骗人**） |

**处置**：**从 Web UI 卸载**（CLI 会拒绝：`Failed to uninstall … please uninstall it from Web UI`）
后重新安装。卸载只需在应用中心点一次；装之前用
`appcenter-cli check <app>` 确认是 `Not Installed`、`/vol2/@appcenter/<app>` 已清。

应急修复（不动数据、可重复执行；**仅在无法卸载重装时使用**）：

```bash
# ① 补齐缺的 .pnpm 实体（只补缺，不动已有）
zcat x.fpk | tar -xOf - app.tgz > /tmp/a.tgz && mkdir -p /tmp/a && tar -xzf /tmp/a.tgz -C /tmp/a
for d in /tmp/a/node_modules/.pnpm/*/; do n=$(basename "$d"); \
  [ -e "$AD/node_modules/.pnpm/$n" ] || cp -a "$d" "$AD/node_modules/.pnpm/"; done
# ② 三层链接补齐 + 纠正错链（用打包脚本同一份实现，幂等）
python3 build/fix-node-links.py "$AD"
# ③ 重启（走平台自己的路径，便于直接看 error.log 有没有新增 10330）
appcenter-cli stop <app> && appcenter-cli start <app>
```

## 九、★「打开」按钮反复消失 → fnOS 应用中心判启动失败（error 10330）

**症状**：FPK 装好后应用其实在跑（三端口在听、套件 200），但应用中心的「打开」按钮不出现；
手动补 `/var/apps/<app>/ui/config`、重启、重装都只能暂时缓解，**反复复现十余次**。

**真因（2026-10-10 真机定位，两处 bug 叠加）**：
1. 生成的 `cmd/main` **调用了 `running_dsh` 却没有定义它**（实现只在 `scripts/lib/common.sh`）
   → 真机实测 `cmd/main status` 报 `running_dsh: 未找到命令`，`rc=3`。
2. 生成物里用的是 `$FPK_DSH_PORT`，而它是**打包脚本**的变量；生成物是 `<<'EOF'` 引号 heredoc，
   **运行时该变量为空** → `running_dsh` 拿到空端口 → status 恒失败。

**判定链（权威证据）**：
- `/var/log/trim_app_center/error.log`：`msg="start app error" ... error="10330:"`
  （`appstore/core/service/start.go:357 StartService.run`）
- 同期应用日志全绿 → 说明是**应用中心的启动判定**失败，不是应用没起来。

**修法**：把 `running_dsh` 的实现（与 `common.sh` 逐字一致）复制进两个生成物；
`start_process` 改为有界轮询（最多 10 秒，命中即返回；超时但 `start.sh` 已成功 spawn 也返回 0，
交给系统 status 轮询判定）；端口变量改用运行时值 `${DSH_PORT:-$FPK_DSH_PORT}`。

**真机复测（2026-10-10）**：`cmd/main status` → `✓ 服务运行中` rc=0；
`appcenter-cli start` → 返回码 0；`error.log` 中 10330 计数启动前后不变（无新增）；
按钮出现（用户确认「修好了」）。

### 9.1 生成物静态体检（定位这类 bug 的通用手段）

<details>
<summary><b>展开：静态体检脚本（可直接复制运行；已抽出实测通过）</b></summary>


两个生成物都是**引号 heredoc**（`<<'EOF'` / `<<'SSS_EOF'`）→ 里面的变量是**打包脚本的变量**，
运行时可能为空；函数定义也不会自动带过去。故每次改动生成物后必跑（把 `SNAP` 当结束标记即可）：

```bash
python3 - <<'SNAP'
import io, re
BUILTIN = set(('if then else elif fi for while do done case esac return exit echo cd mkdir rm cp mv '
               'ln tar sed awk grep cut tr date sleep kill pkill pgrep readlink dirname basename cat '
               'head tail sort uniq wc test printf source export local set shift eval exec command '
               'which type id chmod chown touch stat find xargs tee netstat ss curl true false env').split())

def scan(path, start, term):
    L = io.open(path, encoding='utf-8').read().split('\n')
    st = [i for i, l in enumerate(L) if start in l][0]
    en = [i for i, l in enumerate(L) if i > st and l.strip() == term][0]
    gen = '\n'.join(L[st + 1:en])
    defs = set(re.findall(r'^\s*([A-Za-z_]\w*)\s*\(\)\s*\{', gen, re.M))
    calls = set(re.findall(r'(?:^|[;&|(]\s*|\$\(\s*)([A-Za-z_]\w*)\s', gen, re.M))
    calls |= set(re.findall(r'^\s*([A-Za-z_]\w*)\s*(?:\|\||&&|;|$)', gen, re.M))
    # 排除"赋值/循环变量"造成的误报（如 _w=$((_w+1))、while [ "$_w" -lt 10 ]）
    assigned = set(re.findall(r'^\s*([A-Za-z_]\w*)=', gen, re.M))
    bad = sorted(c for c in calls if c not in defs and c not in BUILTIN and c not in assigned)
    print('%-32s 生成物 %4d 行；未定义调用: %s' % (path, len(gen.split('\n')), bad or '（无）'))

scan('build/FPK/pack-fpk.sh', 'cat > "$FPK_SRC/cmd/main"', 'EOF')
scan('build/SPK/pack-spk.sh', 'cat > "$ASSEMBLE/scripts/start-stop-status"', 'SSS_EOF')
SNAP
```

> 实测本仓库当前输出：FPK 只剩 `break/continue` 两个 shell 关键字误报，SPK 干净 ——
> 只要出现**其它**名字就是真缺定义（本轮两个 bug 都是这样被抓出来的）。

**同类检查（生成物内变量为空）**：生成物里出现的 `${FOO}`，若 `FOO` 只在打包脚本里赋值
（引号 heredoc 不展开），运行时即为空 → 必须改用运行时来源或给默认值。

</details>

### 9.2 误判档案（这些结论已被真机推翻，勿再据此排查）

**一句话**：`/var/apps/<app>/ui`、外层 `ui/` 目录条目、ui 复制的成败、图标命名 —— 这四条都**不是**「打开」按钮的原因；按钮只取决于**平台是否判定启动成功**。

<details>
<summary><b>展开：四条被推翻结论的完整对照表</b></summary>


| 曾经的结论 | 证据类型 | 现状 | 正确事实 |
|---|---|---|---|
| `/var/apps/<app>/ui` 是「打开」按钮必需项 | 推断（两向相关） | **已推翻** | 全机 5 个应用（含 1Panel）该路径下都没有 `ui/` 而入口正常；fnOS 读的是应用目录里的 `ui/config`（经 `/var/apps/<app>/target`）。按钮真因是 10330 |
| FPK 外层必须有 `ui/` **目录条目**才算注册门户 | 推断 | **已推翻** | 安全扫描日志明写 `dir: ui` 已被识别；两份包外层目录条目数都是 0，与按钮无关 |
| 按钮消失与 `install_callback` 的 ui 复制有关 | 推断 | **已推翻** | 该复制以包用户身份运行，`/var/apps/<app>` 属 `root:root` → 必然失败（实测 `权限不够`），保留它只是"尽力而为" |
| 图标命名（`icon-` vs `icon_`）导致按钮异常 | 推断 | **不成立** | nginx access.log 实测：`…/serviceicon/<app>/ui/images/icon_%7B0%7D.png?size=256` → **200 / 11426 字节**，图标本来就取得到 |

> **规则**：凡"某文件 / 某字段是必需项"的结论，必须给出**机制**（读哪个配置/日志/二进制字符串）
> 或**控制变量的两向实测**；否则只能写成"推断，待验证"
> （见 `docs/skills/通用开发规范.md` 第 4 章）。

</details>

### 9.3 真机验收判据（改 FPK 启停逻辑后必跑）

```bash
# ① 平台自己的判定（决定性）：启动后不得新增 10330
B=$(grep -ac "start app error" /var/log/trim_app_center/error.log)
appcenter-cli stop <app> >/dev/null; appcenter-cli start <app> >/dev/null
A=$(grep -ac "start app error" /var/log/trim_app_center/error.log)
[ "$B" = "$A" ] && echo "✓ 本次没有新的启动失败" || echo "✗ 又失败了（看 error.log 尾部）"

# ② 生成物自身（曾在真机 rc=3）
TRIM_APPDEST=/vol2/@appcenter/<app> TRIM_PKGVAR=/vol2/@appdata/<app>/<ver> \
  /var/apps/<app>/cmd/main status          # 期望 "✓ 服务运行中" 且 rc=0

# ③ 业务面
appcenter-cli status <app>                  # running
ss -ltn | grep -cE ':3080|:3081|:3082'      # 3
curl -sL -c j -b j -o /dev/null -w '%{http_code}\n' \
     -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-Dest: document' -H 'Accept: text/html' \
     http://<NAS>:3080/                     # 200
```

### 9.4 全新安装端到端验收清单（八条判据）

1. `appcenter-cli status <app>` = **running**
2. 三端口 3080/3081/3082 全监听（`ss -ltn`）
3. 启动日志**0 条** `failed to import` / `did not activate` / `never started`
4. 门户 `ui/config` 与包内原版一致（`icon=images/icon_{0}.png`、`url="/"`、键与 manifest 一致）
5. `cmd/main status` rc=0（平台判定不失败 —— **曾漏掉这条，导致按钮消失**）
6. 数据目录**无** `tmp/`
7. `TMPDIR=/vol2/@apptemp/<app>`
8. 断链 0 条，且顶层/提升/包内三层链接的关键依赖（`commander`、`js-yaml`、
   `@deepseek-ai/cordis`、`@szmarczak/http-timer`、`get-stream`）全部可解析


## 十、2026-10-10 修复实证记录（README 只留结论，细节在这里）

> 汇总表见 README 顶部「🆕 最新更新」；本节保留**命令、输出、日志原文、提交**等实证材料，
> 便于日后复现与追责 —— 每条都可在真机上按命令重跑。

### 10.1 逐条实测证据（真机命令与输出）

**1. 「打开」按钮（error 10330）**
```
真机: sudo <app>/cmd/main status → "行 89: running_dsh: 未找到命令"  rc=3
平台: /var/log/trim_app_center/error.log → msg="start app error" error="10330:"
      （appstore/core/service/start.go:357 StartService.run）
同时: 应用其实在跑（三端口在听、套件 200）→ 是【应用中心的启动判定】失败
修复: 生成物补 running_dsh 定义 + 端口改用 ${DSH_PORT:-$FPK_DSH_PORT} + 有界轮询
复测: cmd/main status rc=0；启动前后 10330 计数不变（无新增）；按钮出现
```

**2. plugin-manager**
```
报错: Named export 'getStreamAsArray' not found. 'get-stream' is a CommonJS module
定位: execa@10.0.1 声明 get-stream ^9.0.1，但 .pnpm/node_modules/get-stream → 5.2.0（CJS）
反证: 只把这一条链改指 9.0.1 → 插件立刻可加载
修复: fix-node-links.py 新增 relink()、start.sh 自愈新增 fixLink()（不只补缺，且纠正错链）
```

**3. otel**
```
报错: Cannot find module '@szmarczak/http-timer'
定位: 该包已在 extra(73) 与 _autoLearned(57) 里，唯独不在 lockfileDeps(489)，
      而模式 B 只读 lockfileDeps + workspaceRuntimeDeps；全仓库无一处读 _autoLearned
修复: 模式 B 并入 _autoLearned → 白名单 489 → 546 项（含 get-stream/@sindresorhus/is/fontkit 等）
```

**4. 顶层链接**
```
实测: 补 661 条顶层链后 commander/js-yaml/cordis/schemastery/dsh-app-boot 全部可解析，应用立刻 running
```

**5. 空转 14m45s**
```
#98 日志: prune 结束 → 上传 artifact 之间【14m45s 无任何输出】，取消时残留进程 pid(3205)(python3)
根因: Python glob 的 ** 会跟随软链下降，裁剪后 .pnpm 实体互为软链 → 组合爆炸
修复: 改 os.scandir（不进 node_modules、不跟随软链）→ 同场景 14m45s → 0m00s
```

**6. action.yml（三次失败）**
```
#99/#101/#102: ##[error]Failed to load ./.github/actions/build-target/action.yml
             System.ArgumentException: Unexpected type '' … 'action manifest root'
根因: 插入步骤用了 6 空格（同级 4 空格）→ YAML 结构坏 → GitHub 拒绝加载整个 action
```

**7. 工具误报**
```
反向自检: check-package-parity.py 把官方 2.0 基准 SPK 当候选 → 报 5638 条悬空
根因: tar 目录条目带结尾斜杠 + 清单路径带 ./ 前缀 → 精确匹配失败
修复: 统一归一化；并把 SPK 悬空判定降级为【提示】（官方基准自身也是同形态）
```

**8. 野生调度器**
```
现象: #104/#106/#108 被误判为"我派的构建"
真相: 早前写的 backfill-all.sh 在后台持续派发（用 pgrep 校验不到，ps 能看到）
处置: 按 pid 彻底停止；规范要求派发前 `ps -ef | grep -c '[b]ackfill-all'` 必须为 0
```

**9. 覆盖安装不拷文件**
```
实测: 同版本 install-fpk 后 .pnpm 仍是 383（新包 398）、bin/start.sh 仍是旧版
处置: Web UI 卸载（CLI 会拒绝：please uninstall it from Web UI）后重装
```




### 10.2 本轮提交清单

| commit | 内容 |
|---|---|
| `ee514d6` | `fix(links)` 修复脚本改为**纠正错链**（plugin-manager 真根因） |
| `073ce77` | `fix(prune)` 出货裁剪并入 `_autoLearned`（otel 真根因） |
| `f5df32c` | `fix(parity)` 悬空判定两处误报（连官方基准包都被误判） |
| `ef99cd2` | `fix(fpk/spk)` 生成物缺 `running_dsh` 定义 + start 只等 3 秒 |
| `ec284c9` | `fix(fpk)` 生成物端口变量改用运行时值（第二处真因） |
| `4e5419c` | `docs(fpk)` 纠正被推翻的 ui 结论 + 写入 10330 真因 |
| `b310660` | `guard(17)` 文案与事实对齐 |
| `8aec15a` | `docs` 新增《通用开发规范》+ 重写 FPK 排障 |
| `3357c05` | `docs(fpk)` 体检脚本去掉赋值变量误报 |
