#!/usr/bin/env node
/**
 * dsh-session-migrate —— DSH 会话跨版本迁移 CLI（零依赖）
 *
 * 为什么存在：DSH 会话格式随 harness 版本演进（0.1.2 写 v0，0.1.5+ 为 v3）。
 * 官方不提供迁移命令，但持久化层在**打开会话**时会自动把低版本 generation
 * 沿迁移边串行还原（v0→v1→v2→v3）。本工具负责把源会话安全投放成目标实例
 * 中一个「可被自动迁移」的 generation，并把已知的格式陷阱挡在前面。
 *
 * 用法:
 *   node cli.mjs list    <DSH_HOME>                    列出会话与布局问题
 *   node cli.mjs check   <文件>                        单文件体检
 *   node cli.mjs fix     <DSH_HOME>                    移出 sessions/ 下非法目录
 *   node cli.mjs import  <源文件|源目录> <DSH_HOME>    双路径导入（含 subagents）
 *   node cli.mjs import  <源> <DSH_HOME> --cwd <cwd>   指定目标 cwd
 *
 * DSH_HOME 可用环境变量 DSH_HOME 提供；未指定时自动探测常见套件路径。
 */
import { existsSync } from 'node:fs';
import { isPlaintext } from './lib/zstd.js';
import { checkArtifact, printList, fixLayout, renderVersionPlan } from './lib/inspect.js';
import { importAuto } from './lib/import.js';

/** 自动探测 DSH_HOME */
function detectHome() {
  if (process.env.DSH_HOME) return process.env.DSH_HOME;
  const cands = [
    '/volume1/@appdata/DeepSeekHarness-NAS/0.1.6-alpha.1/.dsh',
    `${process.env.HOME || ''}/.dsh`,
  ];
  for (const c of cands) if (c && existsSync(c)) return c;
  return null;
}

function usage() {
  console.log(`dsh-session-migrate —— DSH 会话跨版本迁移 CLI

用法:
  node cli.mjs list   <DSH_HOME>                    列出会话与布局问题
  node cli.mjs check  <文件> [--home <DSH_HOME>]    单文件体检（含目标版本与迁移路径）
  node cli.mjs fix    <DSH_HOME>                    移出 sessions/ 下非法目录
  node cli.mjs import <源文件|源目录> <DSH_HOME>    双路径导入
                     可选 --cwd <目标cwd> 覆盖自动映射

说明:
  · import 支持会话导出包解出的目录（自动带上 subagents/*）
  · 明文 session.jsonl 会在导入时转成 zstd（目标 compression=zstd 时必需）
  · 本工具不启动/不停止 DSH；迁移应在 DSH 停止时执行
  · 导入后需启动 DSH 并打开会话，由持久化层完成 v0→v1→v2→v3`);
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);

  if (!cmd || cmd === '-h' || cmd === '--help') { usage(); return 0; }

  if (cmd === 'check') {
    const f = rest[0];
    let homeOpt = null;
    for (let i = 1; i < rest.length; i++) if (rest[i] === '--home') homeOpt = rest[++i];
    if (!f) { console.error('check 需要 <文件>'); return 2; }
    try {
      const r = checkArtifact(f, { home: homeOpt });
      console.log(`  ${r.plaintext ? '明文 jsonl（导入时自动转码）' : 'zstd'}`);
      console.log(`  ✓ 首帧契约满足（恰好一行 header）`);
      if (!r.plaintext) console.log(`    frame 数 : ${r.frameCount}`);
      console.log(`    行数     : ${r.lines ?? r.frameCount}`);
      console.log(`    id       : ${r.id}`);
      console.log(`    cwd      : ${r.cwd || '(无)'}`);
      console.log(`    createdAt: ${r.createdAt}`);
      console.log(renderVersionPlan(r));
      return 0;
    } catch (e) {
      console.error(`  ✗ ${e.message}`);
      return 1;
    }
  }

  if (cmd === 'list') {
    const home = rest[0] || detectHome();
    if (!home) { console.error('list 需要 <DSH_HOME>（或设置环境变量 DSH_HOME）'); return 2; }
    printList(home);
    return 0;
  }

  if (cmd === 'fix') {
    const home = rest[0] || detectHome();
    if (!home) { console.error('fix 需要 <DSH_HOME>'); return 2; }
    fixLayout(home);
    return 0;
  }

  if (cmd === 'import') {
    const src = rest[0];
    let home = rest[1];
    let cwd = null;
    for (let i = 2; i < rest.length; i++) {
      if (rest[i] === '--cwd') cwd = rest[++i];
      else if (!home) home = rest[i];
    }
    home = home || detectHome();
    if (!src || !home) { console.error('import 需要 <源> <DSH_HOME>'); return 2; }
    try {
      importAuto({ src, home, targetCwd: cwd });
      return 0;
    } catch (e) {
      console.error(`  ✗ ${e.message}`);
      return 1;
    }
  }

  console.error(`未知命令: ${cmd}`);
  usage();
  return 2;
}

process.exit(main());
