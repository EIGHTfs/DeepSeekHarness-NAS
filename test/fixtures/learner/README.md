# 自动学习器回归夹具（learner fixtures）

这些文件是 `scripts/learn-prune-whitelist.sh` 的**回归测试数据**，由
`test/learner-dryrun.test.sh` 在 **dry-run** 模式（绝不写盘）下逐条断言。

| 夹具 | 来源 | 期望学到 | 断言要点 |
|---|---|---|---|
| `ts7026-react-types.log` | **真实** CI 失败日志 #132（官方 alpha.3，2026-10-14）第 566–595 行，已去掉时间戳前缀 | `@types/react` `@types/react-dom` `@types/node` `typescript` `react` | 纯类型错（TS7026/TS2339/TS4112）**没有模块名**，必须靠"日志有 JSX 信号 + 源码声明了类型包"两条证据学到；同一段里还有一行 `TS2307 Cannot find module 'react/jsx-runtime'` → 子路径归一为 `react` |
| `ts2307-vite.log` | 依真实教训构造（vite 不被任何包声明却是命脉脚本 import） | `vite` `react` | 模块名规则 + 子路径归一 |
| `ts7016-semver.log` | 依真实教训构造（TS7016 缺的是声明文件） | `@types/semver` | 缺声明 → 学 `@types/<pkg>` |
| `pnpm-missing.log` | 依真实教训构造（postinstall import 失败） | `lefthook` | `ERR_MODULE_NOT_FOUND` 规则 |
| `negative-ts2339-only.log` | **反例**（只有 TS2339、无 JSX 信号） | **空** | 守住"只从真实失败日志学、不猜"的边界：没有证据就一个都不学 |
| `src/package.json` | 夹具用的"源码根 package.json" | — | 提供"已声明的类型包"这一条证据 |

**改动学习器规则时**：先更新这里的夹具与期望，再改代码；`test/learner-dryrun.test.sh`
会同时检查"该学的学到 ✓ / 不该学的没学 ✓ / dry-run 不写盘 ✓"。

---

## 历史失败夹具（`history/`）—— 自动采集，覆盖全部能找到的历史 CI 失败

采集器：`python3 scripts/collect-failure-fixtures.py [--limit N] [--dry-run]`
- 列出本仓所有 `conclusion=failure` 的 run（分页）→ 取失败 job 的日志 →
  抽取"学习器关心的错误行"（去时间戳/ANSI）→ 按签名去重 → 落盘；
- 只读远端、只写 `history/`；**绝不**改白名单、**绝不**改 `baseline.json`；
- 会跳过"日志过短/无特征行"的 run（避免空样本污染回归集）；
- 产出 `index.json`（run/日期/job/签名/重复 run）与 `proposed-expected.json`（**建议值，必须人工复核**）。

当前覆盖：**21 个历史失败 run**（2026-09-14 ~ 2026-10-14），涵盖
`Cannot find module/package`、`TS2307/TS7016`、`ERR_PNPM_OUTDATED_LOCKFILE`、
`ERR_PNPM_UNUSED_PATCH`、action.yml 加载失败、artifact 缺失、命名守卫失败、
网络取 tag 失败、以及本次事故的"纯类型错"（#132 TS7026/TS2339/TS4112）。

## 固定基线（`baseline.json`）—— 测试的判定依据

```jsonc
{
  "files": {
    "history/082-build-target.log": { "must": ["papaparse"], "why": "TS2307 papaparse（官方脚本 import）" },
    "history/011-build-spk.log":    { "empty": true,        "why": "ERR_PNPM_OUTDATED_LOCKFILE：锁文件过期，不是缺包" }
  }
}
```

判定（用户 2026-10-15 定）：

| 情形 | 判定 |
|---|---|
| 基线 `must ⊆ 实际检出` | ✅ 通过（学习器**多学**属合法改进，允许） |
| 基线里缺任何一项 | ❌ 失败（这才是回归） |
| `empty: true`（负例） | 检出**必须为空** ✅（否则"期望空"用子集判定会永远通过，失去意义） |
| dry-run 后白名单 sha256 变化 | ❌ 失败（学习器只许在 `--apply` 时写盘） |

更新基线（可随时把"当前正确识别结果"固化为固定结果）：

```bash
bash test/learner-dryrun.test.sh --update-baseline
```
- 只把**正例**的 `must` 更新为当前检出；**负例保持空**并打印告警（防止把"瞎学"固化成基线）；
- 更新后请复核 `git diff test/fixtures/learner/baseline.json`（每条的 `why` 里写了依据）。

**接入**：CI 守卫步骤每次构建前跑 `bash test/learner-dryrun.test.sh`；不变量 [26] 断言
"学习器有类型错规则 + `--src`/`--json` + 夹具/测试/基线齐全"（防误删）。
