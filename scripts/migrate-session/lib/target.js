/**
 * 目标机器能力探测：当前会话格式版本、可用迁移边、可读版本范围。
 *
 * 数据来源（**不硬编码版本号**，全部从目标安装的源码读）：
 *   packages/core/session/src/types.ts
 *     → `export const SESSION_FORMAT_VERSION = N`
 *   packages/session/session-format-catalog/src/generated.ts
 *     → `createSessionFormatCatalog({ currentVersion, migrations: [...] })`
 *
 * 为什么动态读：会话格式仍属预发布格式，版本号随 harness 版本演进；
 * 硬编码会在升级后静默失准。探测失败时降级为「未知」，不影响导入本身。
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * 从安装目录探测会话格式能力。
 * @param {string} installRoot DSH 安装根（含 packages/），如 /var/packages/X/target
 * @returns {{ ok:boolean, currentVersion:number|null, migrations:Array<{from:number,to:number,name:string}>, readable:number[], source:string, note?:string }}
 */
export function detectTarget(installRoot) {
  const out = { ok: false, currentVersion: null, migrations: [], readable: [], source: '', note: '' };
  if (!installRoot || !existsSync(installRoot)) {
    out.note = `安装目录不存在: ${installRoot || '(未提供)'}`;
    return out;
  }

  // ① 当前版本：优先读 src，回退读编译产物
  const cands = [
    join(installRoot, 'packages/core/session/src/types.ts'),
    join(installRoot, 'packages/core/session/lib/types/types.js'),
  ];
  for (const f of cands) {
    if (!existsSync(f)) continue;
    const t = readFileSync(f, 'utf8');
    const m = /SESSION_FORMAT_VERSION\s*=\s*(\d+)/.exec(t);
    if (m) { out.currentVersion = Number(m[1]); out.source = f; break; }
  }

  // ② 迁移边 + currentVersion（更权威，来自 generator 产物）
  const gen = join(installRoot, 'packages/session/session-format-catalog/src/generated.ts');
  if (existsSync(gen)) {
    const t = readFileSync(gen, 'utf8');
    const cv = /currentVersion:\s*(\d+)/.exec(t);
    if (cv) { out.currentVersion = Number(cv[1]); out.source = gen; }

    const mig = /migrations:\s*\[([^\]]*)\]/.exec(t);
    if (mig) {
      for (const raw of mig[1].split(',')) {
        const name = raw.trim();
        if (!name) continue;
        const m = /V(\d+)ToV(\d+)/.exec(name);
        if (m) out.migrations.push({ from: Number(m[1]), to: Number(m[2]), name });
      }
      out.migrations.sort((a, b) => a.from - b.from);
    }
  }

  // ③ 可读版本 = codecs 列出的版本
  const codecs = join(installRoot, 'packages/session/session-format-catalog/src/generated.ts');
  if (existsSync(codecs)) {
    const t = readFileSync(codecs, 'utf8');
    const m = /codecs:\s*\[([^\]]*)\]/.exec(t);
    if (m) {
      const vs = new Set();
      for (const raw of m[1].split(',')) {
        const mm = /V(\d+)SessionFormatCodec/.exec(raw.trim());
        if (mm) vs.add(Number(mm[1]));
      }
      out.readable = [...vs].sort((a, b) => a - b);
    }
  }

  out.ok = out.currentVersion !== null;
  if (!out.ok) out.note = '未能从安装目录读取版本信息（不影响导入，仅缺少版本规划）';
  return out;
}

/**
 * 规划从源版本到目标版本的迁移路径。
 * @param {number} fromVersion 源文件 header.version
 * @param {object} target detectTarget() 的结果
 * @returns {{ steps:Array<{from:number,to:number,name:string}>, alreadyCurrent:boolean, possible:boolean, reason?:string }}
 */
export function planMigration(fromVersion, target) {
  if (target?.currentVersion === null || target?.currentVersion === undefined) {
    return { steps: [], alreadyCurrent: false, possible: false, reason: '未知目标版本' };
  }
  if (fromVersion === target.currentVersion) {
    return { steps: [], alreadyCurrent: true, possible: true };
  }
  if (fromVersion > target.currentVersion) {
    return {
      steps: [], alreadyCurrent: false, possible: false,
      reason: `源版本 v${fromVersion} 高于目标的 v${target.currentVersion}（官方无降级迁移边）`,
    };
  }

  // 沿迁移边贪心前进：每次找一条 from === 当前版本 的边
  const steps = [];
  let cur = fromVersion;
  const seen = new Set();
  while (cur < target.currentVersion) {
    if (seen.has(cur)) return { steps, alreadyCurrent: false, possible: false, reason: '迁移链存在环' };
    seen.add(cur);
    const edge = (target.migrations || []).find((m) => m.from === cur);
    if (!edge) {
      return {
        steps, alreadyCurrent: false, possible: false,
        reason: `缺少 v${cur} 的迁移边（目标仅提供 ${(target.migrations || []).map((m) => `v${m.from}→v${m.to}`).join(', ') || '无'}）`,
      };
    }
    steps.push(edge);
    cur = edge.to;
  }
  return { steps, alreadyCurrent: false, possible: true };
}

/** 探测 DSH 安装根（可从 DSH_HOME 反推，或扫常见套件路径） */
export function detectInstallRoot(dshHome) {
  const cands = [];
  if (process.env.DSH_INSTALL_ROOT) cands.push(process.env.DSH_INSTALL_ROOT);
  cands.push(
    '/var/packages/DeepSeekHarness-NAS/target',
    '/volume1/@appstore/DeepSeekHarness-NAS',
  );
  if (dshHome) {
    // <appdata>/<ver>/.dsh → 套件 target
    cands.push(join(dshHome, '../../target'));
  }
  for (const c of cands) {
    if (c && existsSync(join(c, 'packages/session'))) return c;
  }
  return null;
}
