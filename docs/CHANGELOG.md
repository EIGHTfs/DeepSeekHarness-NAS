# 更新记录（CHANGELOG）

> 本文件承载**历史更新**。README 只保留"现在是什么样、怎么用"，不再逐条记录演变过程。
> 每条一行；同一日期内按"改动面"归类。**解释性内容（为什么这么做、踩过什么坑）见 `docs/skills/`。**

## 2026-10-09

**CI / 自动化**
- 新增官方更新看门狗 `watch-official.yml`：每 30 分钟比对官方最新 tag ↔ 本仓最新 Release tag；未对齐、且无构建在跑、且距上次成功构建 ≥6 小时 → 自动触发构建。判定无状态。
- 取消每日 04:00 UTC 定时构建：它与看门狗的"成功后暂停 6 小时"口径冲突（cron 是无条件构建）。
- 新增**失败自愈（方案 B）**：`build-target` 失败时从真实失败日志反查缺失依赖（含 `Could not find a declaration file for module 'X'` → `@types/X` 映射），学进裁剪白名单后 commit + push 入库，并自动重建一次；白名单无变化则不提交（无死循环）。
- 修复方案 B 两个缺陷（#84 实测暴露）：`changed` 输出必须写在 `push` **之前**；重建步条件必须用 `always()` 而非 `failure()`。

**依赖安装**
- `build-common.sh` 装依赖前**并发探测** npm 候选源，取【HTTP 2xx/3xx 且耗时最短】者（`NPM_REGISTRY_CANDIDATES`，加镜像只加一行）。
- 参数类错误（`Unknown option` / `ERR_PNPM_BAD_OPTION` / `ERR_PNPM_INVALID`）不再重试（原先白等 3×30 秒）。
- 修复 `_pnpm_install` 传空参数导致的 `Unknown option: 'frozen-lockfile'` 误报。

**源码获取**
- `fetch-dsh-latest.sh` 固化快通道 `DSH_GIT_MIRROR_PREFIX`（与 dsh-git-push 插件 `lib/git/endpoints.js` 同一口径；默认关，`api.github.com` 不走镜像）。

**裁剪白名单**
- 自动学习补入 `papaparse`、`@types/papaparse`（官方 alpha.2 新增 `scripts/primary-runtime/prune-python-tests.ts` 引入）。

**网页安装工具（路径 A 前端改造）**
- 建立设计令牌层（`:root`），行内 `style=` 72 处 → 0 处。
- 按 WCAG 修正全部不达标配色（23 组配对逐一验算，最低 4.71:1）。
- 补响应式（原 0 个 `@media`）；启用暗色（跟随系统 + 顶栏手动切换，首帧无闪烁）。
- `innerHTML` 6 处 → 0 处（改 DOM API 构造），行内 `onclick` → `addEventListener`。
- 修复 `install.html` 跨行字符串导致**整页 JS 失效**的 P0。
- 新增守卫 `check-html-inline-js.py`（用 `node --check` 真解析内联 JS）。

**文档**
- README 精简为"现状 + 用法"；历史更新移入本文件；解释性内容移入 `docs/skills/`。
- 删除 README「已知待办」节（CSP 一项的说明改由 `install.html` 的豁免注释承载）。

## 2026-10-08
- 网页安装工具新增「构建参数」面板 + `/api/build-config`：品牌/简介/端口可按次覆盖，版本号同步官方不可自定义。
- SPK 入参命名空间统一为 `SPKCFG_*`（与 FPK 的 `FPKCFG_*` 对称），并让环境覆盖真正生效（YAML 不再无条件覆盖）。
- 新增 `config/` 目录：只存可入库模板（`*.default.json`），脚本实读位置不变。

## 2026-10-07
- 门户入口 URL 无条件携带 token（方案 A）：`gen-portal --token` + 运行期 `sync_portal_token()`。
- 新增 `scripts/prune-release-assets.py`：发布后清理改名残留的旧产物资产（默认启用，`vars.PRUNE_OLD_ASSETS=false` 关闭）。
- 删除 `build/build-excludes.json` 中已废弃的 `slim` 段。
- SPK 产物文件名改用完整版本（与 FPK 统一）。

## 2026-10-06
- 新增 `docs/反代媒体请求内部直通设计-20261006.md`（设计文档）。

## 2026-10-05
- `start.sh` 支持 `gen-portal --token`；门户配置与 token 轮换对齐。

## 2026-10-04
- CI 重构为 2 个 job（`build-target` / `pack-and-release`），构建只做一次。
- 新增「保留数据」勾选框：卸载/修复默认保留 `@appdata`/`@apphome`/`@appshare`。
- 新增守卫：`check-workflow-yaml.py` / `check-build-naming.py` / `check-common-functions.py`。
- FPK 两条链路（源码 + npm）一律都构建，取消 `FPK_MODE` 开关。

## 2026-10-03
- 新增网络容错：`npm_config_fetch_timeout=600s` + `retries=5` + 失败重试 3 次 + `npmmirror` 兜底。
- `build-config.yaml` 成为端口与品牌元数据权威源；脚本内禁止写死端口。
- 新增 `learn-prune-whitelist.sh`（白名单自动学习，含 TS7016 → `@types/X` 映射）。

## 2026-10-02
- `fetch-dsh-latest.sh` 不再自找凭据文件（token 只接受显式传入）。

## 2026-09-15
- `install-config.json` 归位 `web-install/`（与脚本同目录，单一来源）。

## 2026-09-14
- 新增 install 前白名单裁剪（`prune-target.sh --before-install`），修复 CI 磁盘爆盘。
- `--no-frozen-lockfile`：裁剪 devDeps 后 lockfile 不一致，CI 默认 frozen 会拒绝安装。

## 2026-09-13
- 新增 `gen-prune-whitelist.sh`（从 npm 链路 `package-lock.json` 生成 `lockfileDeps`）。
- 新增 SPK/FPK 打包验收清单（历史文档）。

## 2026-09-12
- `native/` 排除策略定案：`node-addon-system-linux-x64` 软链真身必须保留。
- `build-config.yaml` 迁移至 `build/`。

## 2026-09-11
- 确立配置文件职责分离（`install-config.json` 连接配置 / `build-config.yaml` 打包权威）。
