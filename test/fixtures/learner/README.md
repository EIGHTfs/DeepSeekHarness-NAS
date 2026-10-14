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
