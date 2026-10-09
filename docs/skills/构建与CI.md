# Skill：构建与 CI

> 本文件承载**构建链与 CI 的解释性内容**（机制原理、边界、历史教训）。
> README 只给"怎么用"，不重复这里的推导过程。

## 1. 构建只做一次

`build-common.sh` 负责 `install + build + 裁剪` 一次完成，产出 `target`；
`pack-spk.sh` / `pack-fpk.sh` 只消费 `target`，不再重复编译。
CI 中 `build-target` 产出 target artifact，`pack-and-release` 复用 —— 这是"两个 job"分工的由来。

## 2. 裁剪白名单（`build-prune-whitelist.json`）

裁剪（`prune-target.sh`）是**纯白名单**语义：不在白名单里的 `.pnpm` 目录一律删除。
白名单三层合成，任一层漏掉都会表现为"包明明装了却找不到"：

| 层 | 来源 | 维护方 |
|---|---|---|
| `lockfileDeps` | `gen-prune-whitelist.sh` 从 npm 链路 `package-lock.json` 的 packages 键解析 | 脚本自动 |
| `workspaceRuntimeDeps` | 动态扫描 `target/packages/**/package.json` 的 `dependencies` | 打包期自动 |
| `extra` + `_autoLearned` | 构建工具/类型检查包；`_autoLearned` 由 `learn-prune-whitelist.sh` 自动学习 | 手工 + 自动 |

**口径**：`extra` 只在模式 A（install 前）用于保护 tsc；`gen-prune-whitelist.sh` 只动 `lockfileDeps`，不覆盖人工项。

### 自动学习（`learn-prune-whitelist.sh`）

两种模式，能力边界不同：

| 模式 | 输入 | 覆盖范围 | 盲区 |
|---|---|---|---|
| `--scan <SRC>` | 官方源码 | `package.json scripts` 引用的入口脚本（含其相对 import 递归），∩「将被剥离的根 devDeps」 | **官方新增"非入口的构建期脚本"扫不到**（实测 alpha.2 的 `scripts/primary-runtime/prune-python-tests.ts` 即属此类） |
| `--log <FILE>` | 构建/安装日志 | `Cannot find module/package 'X'`；`Could not find a declaration file for module 'X'` → `@types/X` | 依赖日志本身能反映问题 |

**CI 用的是 `--log`**（喂真实失败日志）—— 这是它能兜住"非入口脚本"的原因。

## 3. 失败自愈（方案 B，`.github/workflows/build.yml`）

`build-target` 失败时自动执行两步：

1. **自动学习缺失依赖并入库**：从 `build/master-build/*.log` 与 `assets/pnpm-install.log` 反查缺失包 → `--apply` 写白名单 → commit（author `EIGHTfs`）→ `fetch + rebase + push`。
2. **入库后自动重建一次**：仅当①确实改了白名单时触发。

**安全边界（刻意设计）**

- 只按真实失败日志学，不做任何猜测；日志里没有缺失包信息就不动仓库。
- 白名单无变化**绝不提交** → 非缺包类失败不会触发重建，**不存在死循环**。
- 缺包类失败每轮至少并入 1 个包 → 有限次收敛。

**两个实现要点（#84 实测踩出来的，改动时勿回退）**

- `changed` 输出必须写在 `git push` **之前**：push 被拒（并发提交很正常）会让该步被判失败，输出就丢了，重建步随后被 skipped，学到的条目随被拒的提交一起消失。
- 重建步的条件必须是 `always() && steps.selfheal.outputs.changed == 'yes'`：只用 `failure()` 时，上一步自身失败会导致本步被 skipped。

## 4. 官方更新看门狗（`watch-official.yml`）

官方不会给我们发 webhook，轮询是唯一可行的自动对齐手段。代价极小：每 30 分钟一次 `api.github.com` 调用（实测 1~4 秒），且只在确实需要时才触发完整构建。

**判定无状态**（不依赖任何额外存储），三条件全满足才触发：

1. 官方最新 tag ≠ 本仓最新 Release tag（还没对齐）；
2. **当前没有构建在跑** —— `build.yml` 是 `cancel-in-progress: true`，插队会把正在跑的取消掉；
3. 距最近一次**成功**构建 **≥6 小时**（成功后暂停 6 小时）。

**每日定时已取消（2026-10-09）**：cron 是**无条件**构建，若上次成功在 1 小时前它照样跑，等于废掉第 3 条；而看门狗每 30 分钟轮询（48 次/天）本身已是兜底。

## 5. npm 源选择

装依赖前**并发探测**候选源（`NPM_REGISTRY_CANDIDATES` 数组，加镜像只加一行），每个一次请求、超时 4s，取【HTTP 2xx/3xx 且**耗时最短**】者。

**规则是"最快者胜"而不是"先回者胜"**：本机实测 `registry.npmjs.org` 返回 200 但耗时 5.99s（"假可用"，几乎等于超时），`registry.npmmirror.com` 仅 0.63s —— 按列表顺序选会选错。海外 runner 上会自然选中 npmjs，两地自适应。

配套两条：

- **参数类错误不重试**：日志出现 `Unknown option` / `ERR_PNPM_BAD_OPTION` / `ERR_PNPM_INVALID` 立即中止（实测该错误连报 3 次、每次还 `sleep 30`，白等 90 秒）。
- 所选源仍失败时，保留 `npmmirror` 兜底一次。

## 6. 缓存与源码通道

| 缓存 | 键 | 换 tag 后 |
|---|---|---|
| 源码 git 镜像 `src/deepseek-ai/.cache` | `dsh-src-mirror-<repo>-<hash(build-config.yaml)>` | ✅ 命中，只拉增量 |
| pnpm store `assets/pnpm-store` | `pnpm-store-<os>-<hash(pnpm-lock.yaml)>` | ✅ 命中 |
| target `reuse-target.tar.gz` | `dsh-target-v2-<tag>-<hash(构建脚本)>` | ❌ 必然未命中 → 完整构建 |

target 键里带 tag 是**必要**的：target 是源码编译产物，换 tag 复用旧 target 会产出"版本号是新的、代码是旧的"的包。

**快通道**：`fetch-dsh-latest.sh` 支持 `DSH_GIT_MIRROR_PREFIX`（如 `https://gh-proxy.com/`），把 git 协议的 `https://github.com/` 改写走镜像。口径与 dsh-git-push 插件 `lib/git/endpoints.js` **完全一致**：默认关、仅 web/raw/codeload 类走镜像、`api.github.com` 不走镜像（API 是逐 blob、为断点续传设计的，改基址会破坏可续性）。

> 背景数据：本机直连 codeload 21KB/s、`github.com` 不可达、不支持 Range（多线程分片无效）；走镜像 9.34MB/s（约 440 倍），首次建镜像 + 出快照全程 2 分 26 秒。
