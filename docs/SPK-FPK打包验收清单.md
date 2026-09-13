# SPK / FPK 打包验收清单（需求 × 脚本实现对照）

> 生成：2026-09-11｜用途：逐条核对打包需求与「build.sh / 产物整包」的实现对照
> 核对方法：需求记录提取 + 整包解包实测（release 两个 -dist 整包、-3 旧包）

---

## 〇、结论摘要

| 项 | 结论 |
|---|---|
| 当前 release 两个 -dist 整包 | ✅ 已含完整 token 302 逻辑（解包 diff 与母版 0 差异） |
| 历史 -3 版 spk（9/9 脚本产物） | ❌ **违背当初设计**：版本号带 build（0.1.5-3）、token 逻辑为旧版（缺 SameSite=Lax / 401 兜底） |
| `scripts/start.sh` vs `start.sh.spk` | ⚠️ 双文件并存，旧版 `start.sh`（06:46）token 逻辑弱（302 仅 1 处），新版 `start.sh.spk`（14:11）为 build.sh 唯一引用母版（token 8 处）——旧文件是「手操验证版未回写脚本」的历史残留 |
| 一键脚本参数化 | ✅ 源码/类型/说明/APP_NAME/SLIM/SKIP_BUILD 均可命令行覆盖 |

---

## 一、打包需求记录

| # | 需求 |
|---|------|
| R1 | 启动脚本可命令行自定义 3 个端口 |
| R2 | 局域网访问自动重定向带 token |
| R3 | 30800 直接重定向到带 token |
| R4 | 首次访问带 token，之后免密 |
| R5 | token 不暴露给前端 |
| R6 | dsh 访问带 token 后自动隐藏 |
| R7 | DSM 门户经**自动跳转**带 token（非 cookie） |
| R8 | DSM 门禁保留，过门禁后才自动带 token |
| R9 | 群晖门户打开 = 直接访问带 token 的网址 |
| R10 | 飞牛门户打开自动带 token |
| R11 | SPK 版本号取官方**前三位**，不带 build 号，相同覆盖 |
| R12 | FPK 版本号直接官方同步（完整版本） |
| R13 | 品牌改为 DeepSeekHarness-NAS |
| R14 | 界面小字完整版本号 |
| R15 | 一键编译打包脚本 |
| R16 | 卸载无残留 |
| R17 | 验证通过的包放 release 文件夹 |
| R18 | 四种打包均能成功安装 |
| R19 | dist 后缀只给全量包 |
| R20 | 网页端套件打开携带 token |

---

## 二、脚本实现对照表（build.sh / 母版 / 产物实测）

| 要求 | 实现位置 | 实现状态 | 实测验证 |
|------|----------|----------|----------|
| R1 三端口自定义 | build.sh + start.sh.spk（`--proxy-port/--dsh-port/--container-port`） | ✅ 已实现 | SPK=30800/30801/30802；FPK=3080/3081/3082，sed 派生正确 |
| R2/R3 局域网自动重定向带 token | start.sh.spk `autoAuthRedirect`（302→`?token=`） | ✅ 已实现 | 整包解包 grep：当前两整包均含；**-3 版仅含简单版** |
| R4 首访带 token 后免密 | start.sh.spk：无 `dsh-auth` cookie → 302 带 token → dsh 303 收敛 Set-Cookie | ✅ 已实现 | 整包内逻辑完整 |
| R5 token 不暴露前端 | token 仅出现于 URL 查询串，经 dsh 303 收敛后消失 | ✅ 已实现 | 注释 + 逻辑核对 |
| R6 token 自动隐藏 | dsh 认证后 303 到干净 URL | ✅ 已实现 | 同 R4 链路 |
| R7 DSM 门户自动跳转带 token | `ui/config`（type=url, port=30800）+ start.sh 302 兜底 | ✅ 已实现 | INFO dsmappname 与 ui/config 键名一致（`SYNO.SDS.DeepSeekHarness-NAS.Application`） |
| R8 DSM 门禁保留 | 门户由 DSM 登录门禁保护，套件入口仅在登录后可达 | ✅ 设计如此 | archieved by DSM 平台 |
| R9 群晖门户打开=带 token 网址 | ui/config + 302 | ✅ 已实现 | 同上 |
| R10 飞牛门户打开自动带 token | FPK `ui/config`（type=iframe, port=3080）+ start.sh 302 | ✅ 已实现 | manifest appname=`DeepSeekHarness-NAS` 与 ui/config 键名一致 |
| R11 SPK 版本前三位无 build | build.sh `SPK_VERSION="${PKG_VER%%-*}"` 段 | ✅ 已实现 | 当前 -dist：`version="0.1.5"`；**-3 版：`version="0.1.5-3"` ❌ 违背设计** |
| R12 FPK 版本完整同步 | manifest `version=0.1.5-alpha.1` | ✅ 已实现 | 整包实测一致 |
| R13 品牌 DeepSeekHarness-NAS | build.sh 全局 sed 替换 | ✅ 已实现 | INFO/conf/ui/manifest 全替换，整包实测一致 |
| R14 小字完整版本号 | 构建注入 DSH_CLIENT_VERSION/COMMIT_HASH | ✅ 已实现 | README 承诺 + 构建段核对 |
| R15 一键脚本 | `build.sh [SRC] [spk\|fpk\|both] [DESC] [APP_NAME] [SLIM] [SKIP_BUILD]` | ✅ 已实现 | 多次实跑 |
| R16 卸载无残留 | installer preuninst 清理 + `clean-dsm-residue.sh` | ✅ 已实现 | 实测「✅ 无残留」 |
| R17 release 只放测试通过 | build.sh 输出 `build/staging/` + `promote-release.sh` 提升 | ✅ 已实现 | 流程确立 |
| R18 四变体可装 | spk/fpk × slim/full 四产物 | 🔄 全部实测中 | SPK-full ✅（装/端口/网页/卸）；SPK-slim 构建中；FPK 有待验 |
| R19 dist 后缀仅全量 | `_DIST_SUFFIX` 仅 SLIM=0 时追加 | ✅ 已实现 | staging 无 -dist、release 有 -dist，实测一致 |
| R20 网页端套件打开携带 token | 见 R7/R9/R10 链路 | ✅ 代码已实现 | ⏳ 待人工真机截图确认 |

---

## 三、发现的问题（按当初设计核对）

### P1（已解决）当前整包 token 逻辑 = 母版 ✅
- 对比：`sed 's/deepseek-harness-nas/DeepSeekHarness-NAS/g' start.sh.spk` 与 release 整包内 `start.sh` **diff 0 行**。
- 结论：当前脚本产物**已完整携带** token 302 + SameSite=Lax + 401 兜底逻辑，README「门户免密」承诺在代码链路成立。

### P2（历史遗留）`-3` 版 spk 违背当初设计 ❌
- `DeepSeekHarness-x86_64-0.1.5-3.spk`（9/9 10:14，537MB）解包实测：
  - `INFO version="0.1.5-3"` → **违反 R11「SPK 版本号不带 build 后缀，取官方前三位」**；
  - 内嵌 start.sh 为旧版：**无** `SameSite=Lax` 修复、**无** 401 兜底、**无** dsh-auth cookie 认证链（grep 命中 0 vs 母版 11）→ **违反 R2/R6/R7**（token 自动隐藏与门户跨站 cookie 修复）;
  - ui/config 键名 `SYNO.SDS.deepseek-harness-nas.Application`（小写旧键），与 INFO dsmappname 虽一致，但包名未品牌化为 DeepSeekHarness-NAS 内部结构。
- 结论：**-3 是「手操成功、脚本未同步」的产物**，该版本号带 -3 且 token 问题未解决。

### P3（隐患）`scripts/start.sh` 与 `scripts/start.sh.spk` 双文件并存 ⚠️
- `scripts/start.sh`（06:46，24KB）：token 302 仅 1 处，**无** SameSite 修复/401 兜底/版本隔离数据目录；
- `scripts/start.sh.spk`（14:11，31KB）：build.sh 唯一引用母版（377/554 行），token 8 处、含精简包首启构建、版本隔离。
- 风险：后续若误改/误读 `start.sh` 会再出现「手操改错文件」；且 diff 显示两者功能差异巨大（is_instance 路径、node 查找链、数据目录隔离）。
- 建议：确认 `scripts/start.sh` 是否仍被任何运行路径引用；若无引用建议删除或加「已废弃，母版为 start.sh.spk」头注。

### P4（待办）网页端真实渲染验证
- 代码链路（ui/config + 302 + SameSite=Lax）已核对完整，但「DSM 门户点图标 → 携带 token 打开 Web UI」的**真实浏览器行为**需人工截图确认。

---

## 四、核对依据（整包解包实测记录）

| 包 | 位置 | start.sh token 302 | SameSite/401/autoAuth | INFO 版本 | ui/config 键名 |
|----|------|--------------------|----------------------|-----------|----------------|
| DeepSeekHarness-x86_64-0.1.5-dist.spk | release/（22:48） | ✅ | ✅ (11 命中) | `0.1.5` | SYNO.SDS.DeepSeekHarness-NAS.Application |
| DeepSeekHarness-NAS_0.1.5-alpha.1-dist_x86.fpk | release/（22:53） | ✅ | ✅ | `0.1.5-alpha.1` | DeepSeekHarness-NAS.Application |
| DeepSeekHarness-x86_64-0.1.5.spk | staging/（23:14 slim） | 待验（母版一致） | 待验 | 待验 | 待验 |
| DeepSeekHarness-NAS_0.1.5-alpha.1_x86.fpk | staging/（23:16 slim） | 待验 | 待验 | 待验 | 待验 |
| **DeepSeekHarness-x86_64-0.1.5-3.spk** | **回收站（9/9 历史）** | **简单版** | **❌ 0 命中** | **`0.1.5-3` ❌** | **deepseek-harness-nas 小写** |

---

## 五、防再犯

回归反思：任何手动打包/手动改文件验证成功的功能，必须**回写 build.sh / 母版模板**后再宣成「脚本已实现」：

1. **手操验证 ≠ 脚本实现**：手动验证成功不等于脚本已实现，需回写脚本；
2. **产物整包复核**：每次打包后解包抽查产物（start.sh 关键段 / INFO 版本 / ui/config 键名），不只看「打包命令成功」；
3. **版本号纪律**：SPK 永远 `前三位无 build`（0.1.5），出现 `-N` 后缀即视为事故；
4. 删除/归档旧产物前先核对是否含未回写的功能（本次 -3 旧包即历史教训样本）。

---

## 六、2026-09-12 追加：DSM 7.4.1 实测定案 + 预构建包模式

### 6.1 DSM 安装时序实测（与官方文档不符，以实测为准）

- **`synopkg install` 不执行 scripts/installer hooks**（preinst/postinst/prereplace/postreplace 全不跑）：trace 铁证——hook 级 + installer 首行注入 `/tmp/hook-trace.log` `/tmp/installer-ran.log` 反复干净重装全为空；synopkg.log 只有文件 mv/rm + `Acquire systemd-unit` + `start-stop-status start`。
- 官方 scripts.html 声称安装序 = prereplace → preinst → postinst → postreplace → start，**与 DSM 7.4.1 实测不符**。
- 装完 `conf/resource` 从包内 `{}` 变 `{"systemd-unit":{}}` + 生成 `resource.own`（synopkg.log `Acquire systemd-unit … when 0x0001`）。
- **privilege `ctrl-script run-as: root` 拒装**（status 255 non_installed）——官方 privilege_config 声称 6.0-5891 起支持，实测被拒；privilege 保持纯 `run-as: package`。

### 6.2 软链三通道（dsh / pnpm 通用）

1. **installer 三 hook**（postinst/prereplace/postreplace/postupgrade 统一 `setup_pkg_env`，root）——DSM 执行 hooks 时才生效；
2. **远程/网页安装 root 补建**（install-remote-spk.sh 装后 `ln -sf`，最可靠通道，网页 install/repair 同源覆盖）；
3. **start.sh cmd_start 运行时自愈**（幂等 `ln -sf`，fallback `/usr/bin` → `/usr/local/bin` → `$HOME/.local/bin`，须先 `mkdir -p`；DSM 服务以套件用户跑，系统目录不可写时落套件 HOME）。

### 6.3 pnpm 随附 + 软链

- 随包分发 `tools/pnpm`（bin+dist+package.json+pnpm-bridge.py）到 `<target>/pnpm/`；
- `bin/pnpm` 包装器（scripts/pnpm 模板，sed 替换包名路径，用包内 node 跑 pnpm.mjs）；
- `/usr/bin/pnpm` 软链走 6.2 三通道；手动装入 NAS 实测 `pnpm --version` 11.25.0。

### 6.4 打包模式 = 预构建产物包（唯一模式）

- **废弃** 精简/源码包（SLIM 参数）与首启构建；唯一模式 = 本地构建产物 + 裁剪后 node_modules，装完即用；
- **裁剪依据（官方依赖表）**：原生模块 node-pty/sharp/koffi/esbuild/ripgrep 必需（实测裁剪后完好）；构建工具（pnpm/Git/Python/C++）仅源码安装需要 → devDeps 可裁（清单动态读根 package.json，不硬编码）；
- 裁剪段：①非 linux-x64 平台变体+musl ②claude-agent-sdk/codex ③devDependencies 及传递依赖 ④packages|apps src + docs/benchmarks/native；
- 实测：裁剪后解包 714M，`dsh --version` 0.1.5-rc.2 + web HTTP 200；压缩 package.tgz ≈ 274MB（原 315MB）；必需原生模块全部完好。