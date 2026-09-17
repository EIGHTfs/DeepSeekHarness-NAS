/**
 * 会话体检与布局修复。
 */
import { existsSync, mkdirSync, renameSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { listSessions } from './layout.js';
import { readHeaderAny } from './zstd.js';
import { detectTarget, detectInstallRoot, planMigration } from './target.js';

/**
 * 单文件体检：首帧契约 / 帧数 / header 字段。
 * @param {string} path 会话文件
 * @param {object} [opts]
 * @param {string} [opts.home] 目标 DSH_HOME（提供时附带目标版本与迁移路径）
 */
export function checkArtifact(path, opts = {}) {
  if (!existsSync(path)) throw new Error(`文件不存在: ${path}`);
  const r = readHeaderAny(path);
  const h = r.head;
  if (!h.id) throw new Error('header 缺少 id 字段');

  const out = {
    plaintext: r.plaintext,
    frameCount: r.frameCount,
    lines: r.lines,
    id: h.id,
    version: h.version,
    cwd: h.cwd,
    createdAt: h.createdAt,
  };

  // 附带目标机器的版本能力与迁移规划
  const root = opts.installRoot || detectInstallRoot(opts.home);
  if (root) {
    const target = detectTarget(root);
    out.target = target;
    out.installRoot = root;
    out.plan = planMigration(h.version, target);
  } else {
    out.target = null;
    out.plan = null;
  }
  return out;
}

/** 把版本与迁移规划渲染成可读文本 */
export function renderVersionPlan(r) {
  const L = [];
  L.push(`    磁盘版本 : v${r.version}（源文件）`);
  if (r.target?.ok) {
    L.push(`    目标要的 : v${r.target.currentVersion}（${r.installRoot}）`);
    L.push(`    可读范围 : ${r.target.readable.length ? r.target.readable.map((v) => 'v' + v).join(', ') : '(未探测到)'}`);
  } else {
    L.push(`    目标要的 : (未能探测；${r.target?.note || '无安装目录'}）`);
  }
  if (r.plan) {
    if (r.plan.alreadyCurrent) {
      L.push(`    迁移路径 : 已是当前版本，无需迁移`);
    } else if (r.plan.possible) {
      const chain = [`v${r.version}`, ...r.plan.steps.map((s) => `v${s.to}`)].join(' → ');
      L.push(`    迁移路径 : ${chain}  （共 ${r.plan.steps.length} 步）`);
    } else {
      L.push(`    迁移路径 : ✗ 不可迁移 —— ${r.plan.reason}`);
    }
  }
  return L.join('\n');
}

/** 列出会话（文本） */
export function printList(home) {
  const { projects, illegal, sroot } = listSessions(home);
  console.log(`DSH_HOME: ${home}`);
  console.log(`sessions : ${sroot}`);
  console.log('');
  let total = 0;
  for (const p of projects) {
    console.log(`── ${p.dir}`);
    for (const s of p.sessions) {
      const gens = s.generations.map((g) => `${g.file}(${g.size})`).join('  ') || '(无 generation)';
      console.log(`   ${s.id}`);
      console.log(`      ${gens}`);
      total++;
    }
  }
  console.log('');
  console.log(`共 ${projects.length} 个 cwd 目录 / ${total} 个会话`);
  if (illegal.length) {
    console.log('');
    console.log('⚠ 非法目录（会导致 workspaceRegistry 激活失败 → 工作区列表为空）:');
    for (const n of illegal) console.log(`   ${n}`);
    console.log('   → 用 --fix-layout 移出（备份到 <home>/../session-backups/）');
  }
  return { projects, illegal, total };
}

/** 把 sessions/ 根下的裸条目移出（备份保留，可恢复） */
export function fixLayout(home) {
  const { illegal, sroot } = listSessions(home);
  if (!illegal.length) { console.log('  ✓ 布局正常，无非法条目'); return { moved: [] }; }
  const backupDir = join(dirname(home), 'session-backups');
  mkdirSync(backupDir, { recursive: true });
  const moved = [];
  const ts = Date.now();
  for (const name of illegal) {
    const from = join(sroot, name);
    const to = join(backupDir, `${name}.${ts}`);
    renameSync(from, to);
    console.log(`  → 已移出: ${name} → ${to}`);
    moved.push({ name, to });
  }
  console.log(`  ✓ 移出 ${moved.length} 项`);
  return { moved };
}
