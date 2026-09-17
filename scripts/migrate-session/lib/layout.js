/**
 * 会话目录布局：cwd → 目录名编码、目标路径推导、布局校验。
 *
 * 编码规则（实测自 DSH 生成的目录名）：
 *   路径开头 '/'  → 由 "‑‑" 前缀代表（不单独输出）
 *   其余 '/'      → '-'
 *   空格          → '~0020'
 *   安全字符       → 原样（字母/数字/'.'/'_'/'~'/'-'）
 *   其余           → '~XXXX'（Unicode 码点大写十六进制，如 工 U+5DE5 → ~5DE5）
 *
 * 例：/volume1/@appdata/X/0.1.6-alpha.1/工作区
 *     → --volume1-~0040appdata-X-0.1.6-alpha.1-~5DE5~4F5C~533A--
 *
 * 布局契约（踩过的坑）：
 *   sessions/ 根下**只允许** --<编码cwd>-- 形式的目录；任何裸目录（如把备份
 *   放在 sessions/backup-xxx）会让 DSH 报
 *   `uses the unsupported flat-file layout`，进而 workspaceRegistry 激活失败，
 *   表现为「工作区列表为空 + directoryPickerController is unavailable」。
 *   备份一律放 <home>/../session-backups/。
 */
import { readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';

/** cwd 绝对路径 → 会话目录名 */
export function encodeCwd(cwd) {
  let out = '';
  const s = String(cwd);
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    const cp = s.codePointAt(i);
    if (ch === '/') {
      if (i === 0) continue;             // 开头的斜杠由 '--' 前缀代表
      out += '-';
    } else if (ch === ' ') {
      out += '~0020';
    } else if (/[A-Za-z0-9._~-]/.test(ch)) {
      out += ch;
    } else {
      out += '~' + cp.toString(16).toUpperCase().padStart(4, '0');
    }
  }
  return `--${out}--`;
}

/** 会话目录名 → 是否合法（--...-- 形式） */
export function isLegalProjectDir(name) {
  return /^--.*--$/.test(name);
}

/** 一个 generation 文件名 → 版本号（session.jsonl → 0，session.v3.jsonl.zstd → 3） */
export function generationVersion(filename) {
  const m = /^session(?:\.v(\d+))?\.jsonl(\.zstd)?$/.exec(filename);
  if (!m) return null;
  return m[1] ? Number(m[1]) : 0;
}

/**
 * 列出 DSH_HOME 下的全部会话，并暴露布局问题。
 * @returns {{ projects: Array<{dir:string,cwdTail:string,sessions:Array<{id:string,dir:string,generations:Array<{file:string,version:number,size:number}>}>}>, illegal: string[] }}
 */
export function listSessions(home) {
  const sroot = join(home, 'sessions');
  const projects = [], illegal = [];
  if (!existsSync(sroot)) return { projects, illegal, sroot };

  for (const name of readdirSync(sroot)) {
    const pdir = join(sroot, name);
    if (!statSync(pdir).isDirectory()) continue;
    if (!isLegalProjectDir(name)) { illegal.push(name); continue; }

    const sessions = [];
    for (const sidName of readdirSync(pdir)) {
      const sdir = join(pdir, sidName);
      if (!statSync(sdir).isDirectory()) continue;
      const generations = [];
      for (const f of readdirSync(sdir)) {
        const v = generationVersion(f);
        if (v === null) continue;
        generations.push({ file: f, version: v, size: statSync(join(sdir, f)).size });
      }
      generations.sort((a, b) => a.version - b.version);
      sessions.push({ id: sidName, dir: sdir, generations });
    }
    projects.push({ dir: name, sessions });
  }
  return { projects, illegal, sroot };
}

/**
 * 把源 cwd 映射到目标实例的实际路径。
 *
 * 源实例与目标实例结构都是：<实例根>/工作区[/<子项目>]，因此要**保留「工作区」
 * 之后的相对结构**，而不是只看最后一段：
 *   源 .../工作区              → <目标根>/工作区
 *   源 .../工作区/dsh-git-push → <目标根>/工作区/dsh-git-push
 *
 * 退化策略：目标根下无「工作区」时用目标根；对应子项目不存在时回落到工作区根
 * （宁可落到工作区根，也不写一个不存在的路径 —— DSH 按 cwd 推导会话目录名，
 *  不存在的路径会让会话挂在一个没有实际目录的工作区下）。
 *
 * @param {string} srcCwd 源会话 header.cwd
 * @param {string} home 目标 DSH_HOME（<实例根>/.dsh）
 * @returns {string} 目标 cwd 绝对路径
 */
export function deriveTargetCwd(srcCwd, home) {
  const homeRoot = join(home, '..');               // <实例根>
  const wsRoot = join(homeRoot, '工作区');
  const base = existsSync(wsRoot) ? wsRoot : homeRoot;

  const parts = String(srcCwd || '').split('/').filter(Boolean);
  const wsIdx = parts.lastIndexOf('工作区');

  if (wsIdx < 0) return base;                      // 源路径不含「工作区」→ 落工作区根

  const sub = parts.slice(wsIdx + 1);              // 工作区之后的相对段
  if (!sub.length) return base;

  const cand = join(base, ...sub);
  return existsSync(cand) ? cand : base;
}
