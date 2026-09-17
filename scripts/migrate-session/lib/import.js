/**
 * 会话导入：把源（文件或导出包解出的目录）投放进目标 DSH_HOME。
 *
 * 源可以是：
 *   · session.jsonl / session.jsonl.zstd 单文件
 *   · 目录（含 session.jsonl[.zstd] + subagents/<sid>/session.jsonl[.zstd]）
 *
 * 流程：体检 → 备份既有 generation → （必要时明文转 zstd）→ 重写首帧 cwd
 *       → 落盘 → 移走既有 v3（迫使 DSH 重新迁移）→ 逐个投放 subagents。
 *
 * 幂等：重复导入同一会话会先备份既有目录再覆盖。
 * 不做的事：不启动/不停止 DSH —— 迁移应在 DSH 停止时执行。
 */
import { existsSync, mkdirSync, readdirSync, statSync, copyFileSync, rmSync, cpSync, renameSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { encodeCwd, deriveTargetCwd } from './layout.js';
import { isPlaintext, plaintextToZstd, rewriteHeader, readHeaderAny } from './zstd.js';

/** 时间戳串（用于备份命名） */
function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/** 在一个目录里找会话文件（优先明文的 session.jsonl，其次 .zstd） */
function findSessionFile(dir) {
  for (const cand of ['session.jsonl', 'session.jsonl.zstd']) {
    const p = join(dir, cand);
    if (existsSync(p)) return p;
  }
  return null;
}

/**
 * 解析源：返回主会话文件与子会话文件列表。
 * @param {string} src 文件或目录
 */
export function resolveSource(src) {
  if (!existsSync(src)) throw new Error(`源不存在: ${src}`);
  const st = statSync(src);

  if (st.isFile()) return { main: src, subs: [] };

  const main = findSessionFile(src);
  if (!main) throw new Error(`目录中未找到 session.jsonl[.zstd]: ${src}`);

  const subs = [];
  const subRoot = join(src, 'subagents');
  if (existsSync(subRoot)) {
    for (const name of readdirSync(subRoot)) {
      const sdir = join(subRoot, name);
      if (!statSync(sdir).isDirectory()) continue;
      const f = findSessionFile(sdir);
      if (f) subs.push({ id: name, file: f });
    }
  }
  return { main, subs };
}

/**
 * 投放单个会话到 <home>/sessions/<enc>/<sid>/session.jsonl.zstd
 * @param {object} o
 * @param {string} o.home 目标 DSH_HOME
 * @param {string} o.srcFile 源会话文件（明文或 zstd）
 * @param {string} [o.sid] 会话 id（缺省从 header 推导）
 * @param {string} o.targetCwd 写入 header 的 cwd
 * @param {string} [o.into] 目标会话目录（用于 subagent 落进主会话目录）
 * @param {boolean} [o.quiet]
 * @returns {{ sid:string, dir:string, action:string, header:object, frames:number }}
 */
export function installSession({ home, srcFile, sid, targetCwd, into, quiet = false }) {
  const log = (...a) => { if (!quiet) console.log(...a); };
  const sroot = join(home, 'sessions');
  const backupDir = join(dirname(home), 'session-backups');

  // 读 header 以确定 id
  const { head, plaintext } = readHeaderAny(srcFile);
  const sessionId = sid || head.id;
  if (!sessionId) throw new Error('无法确定会话 id（header 缺少 id）');

  const dir = into || join(sroot, encodeCwd(targetCwd), sessionId);
  mkdirSync(dir, { recursive: true });

  // 覆盖前备份（仅当目录已有内容）
  let backupPath = null;
  const before = readdirSync(dir).filter((f) => f !== '.session.incoming.zstd');
  if (before.length) {
    mkdirSync(backupDir, { recursive: true });
    backupPath = join(backupDir, `${sessionId}.before-import-${stamp()}`);
    cpSync(dir, backupPath, { recursive: true });
    log(`  覆盖前已备份 → ${backupPath}`);
  }

  // 明文 → zstd（目标实例 compression=zstd 时必需）
  let workFile = srcFile;
  let tempConverted = null;
  if (plaintext) {
    tempConverted = join(dir, '.session.converted.zstd');
    const r = plaintextToZstd(srcFile, tempConverted);
    log(`  ✓ 明文转 zstd: ${r.lines} 行 → ${r.frames} 帧`);
    workFile = tempConverted;
  }

  // 只重建首帧（其余 frame 原样保留）
  const tmp = join(dir, '.session.incoming.zstd');
  const rw = rewriteHeader(workFile, tmp, { cwd: targetCwd });
  renameSync(tmp, join(dir, 'session.jsonl.zstd'));
  if (tempConverted) rmSync(tempConverted, { force: true });
  log(`  首帧 ${rw.firstFrameBytes[0]}B → ${rw.firstFrameBytes[1]}B；其余 ${rw.restBytes}B 原样保留`);

  // 移走既有 v3：否则 DSH 认为已迁移，不会重跑
  const v3 = join(dir, 'session.v3.jsonl.zstd');
  if (existsSync(v3)) {
    mkdirSync(backupDir, { recursive: true });
    renameSync(v3, join(backupDir, `${sessionId}.v3-prev-${stamp()}`));
    log('  既有 v3 已移出（将重新迁移）');
  }
  const lock = join(dir, 'session.lock');
  if (existsSync(lock)) rmSync(lock, { force: true });

  const check = readHeaderAny(join(dir, 'session.jsonl.zstd'));
  return { sid: sessionId, dir, action: backupPath ? 'replaced' : 'created', header: check.head, frames: check.frameCount, backupPath };
}

/**
 * 双路径导入：源 → 目标 home（含 subagents）。
 * @param {object} o
 * @param {string} o.src  源文件/目录
 * @param {string} o.home 目标 DSH_HOME
 * @param {string} [o.targetCwd] 覆盖目标 cwd（缺省自动映射）
 */
export function importAuto({ src, home, targetCwd }) {
  if (!existsSync(home)) throw new Error(`目标 DSH_HOME 不存在: ${home}`);
  const { main, subs } = resolveSource(src);
  const { head } = readHeaderAny(main);
  const cwd = targetCwd || deriveTargetCwd(head.cwd, home);

  const out = {
    source: src, home, sid: head.id, srcCwd: head.cwd, targetCwd: cwd,
    main: null, subagents: [], results: [],
  };

  console.log(`源主会话 : ${main}`);
  console.log(`子会话数 : ${subs.length}`);
  console.log(`目标 home: ${home}`);
  console.log(`会话 id  : ${head.id}`);
  console.log(`源 cwd   : ${head.cwd}`);
  console.log(`目标 cwd : ${cwd}`);
  console.log('');

  console.log('── 主会话 ──');
  const mainRes = installSession({ home, srcFile: main, sid: head.id, targetCwd: cwd });
  out.main = mainRes;
  console.log(`  落盘: ${mainRes.dir}  (${mainRes.action})`);

  if (subs.length) {
    console.log('');
    console.log('── 子会话（subagents）──');
    for (const s of subs) {
      const subDir = join(mainRes.dir, 'subagents', s.id);
      try {
        const r = installSession({ home, srcFile: s.file, sid: s.id, targetCwd: cwd, into: subDir, quiet: true });
        out.subagents.push({ id: s.id, ok: true, dir: r.dir });
        console.log(`  ✓ ${s.id}`);
      } catch (e) {
        out.subagents.push({ id: s.id, ok: false, error: e.message });
        console.log(`  ✗ ${s.id}: ${e.message}`);
      }
    }
  }

  console.log('');
  console.log(`完成。落盘目录: ${mainRes.dir}`);
  console.log('提醒：需 DSH 启动后打开会话以触发 v0→v1→v2→v3 迁移。');
  out.results = [mainRes, ...out.subagents];
  return out;
}
