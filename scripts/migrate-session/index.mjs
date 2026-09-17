/**
 * dsh-session-migrate 插件入口（DSH 接线）。
 *
 * 形态：`apply(ctx, config)`。
 * 职责：把会话跨版本迁移能力接到 DSH 运行时——
 *   1) 工具注册   ctx.inject(['tools'])        → 模型可调用 3 个工具
 *   2) 系统提示词 ctx.inject(['systemPrompt']) → 一段会话迁移约定
 *   3) HTTP API   ctx.inject(['webServer'])    → /api/session-migrate/*
 * 业务实现全在 lib/（zstd 帧契约 / 目录布局 / 导入 / 体检），
 * 引擎可脱离 DSH 独立运行：`node cli.mjs <子命令>`。
 *
 * 接线约定（来自 dsh-git-push 的实测经验，勿改）：
 *   · 工具返回的 block.content 必须是数组，返回裸字符串会损坏会话日志
 *   · systemPrompt.section 的 text() 必须**同步**返回（async 会让模型看到 [object Promise]）
 *   · 工具 parameters 用简写 spec，必填项写进 description 并在 execute 内校验
 */
import { existsSync } from 'node:fs';
import { checkArtifact, printList, fixLayout } from './lib/inspect.js';
import { importAuto } from './lib/import.js';
import { listSessions } from './lib/layout.js';

/**
 * 动态加载 @deepseek-ai/dsh-tools 的 defineTool。
 * 工作区自测环境没有 DSH 依赖，加载失败返回 null（工具不注册，其它接线照常）。
 */
async function loadDefineTool(log) {
  try {
    const mod = await import('@deepseek-ai/dsh-tools');
    return typeof mod?.defineTool === 'function' ? mod.defineTool : null;
  } catch (e) {
    log?.(`加载 @deepseek-ai/dsh-tools 失败（自测环境属正常）: ${e?.message || e}`);
    return null;
  }
}

/** 插件元信息（DSH 读取） */
export const name = 'dsh-session-migrate';
export const version = '1.0.0';

/** 自动探测 DSH_HOME：显式 config > 环境变量 > 常见套件路径 */
function detectHome(config) {
  const explicit = config?.dshHome || process.env.DSH_HOME;
  if (explicit && existsSync(explicit)) return explicit;
  const cands = [
    '/volume1/@appdata/DeepSeekHarness-NAS/0.1.6-alpha.1/.dsh',
  ];
  for (const c of cands) if (existsSync(c)) return c;
  return explicit || null;
}

/** 工具结果渲染器：必须返回块数组 */
function textRender(_args, value) {
  return [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }];
}

/** 把简写参数 spec 规范成 DSH 参数形状 */
function normalizeParameters(parameters = {}) {
  const out = {};
  for (const [key, spec] of Object.entries(parameters || {})) {
    if (spec && typeof spec === 'object') {
      out[key] = { type: String(spec.type || 'string'), description: String(spec.description || '') };
    } else {
      const raw = String(spec || 'string');
      out[key] = { type: raw.replace(/\?$/, '') || 'string', description: '' };
    }
  }
  return out;
}

/** 工具清单（纯函数，便于单测） */
export function listTools() {
  return [
    {
      name: 'session_migrate_check',
      description:
        '体检一个 DSH 会话文件（.jsonl.zstd 或明文 .jsonl）：校验 zstd 首帧契约（首帧必须恰好一行 header）、统计帧数/行数、读取 id/版本/cwd。' +
        '导入前必跑。若报「首帧不是恰好一行 header」，说明文件被 zstd 整体重压缩过，需要按帧重建。',
      parameters: normalizeParameters({ path: 'string' }),
      render: textRender,
      execute: async ({ path }) => {
        if (!path) throw new Error('需要 path');
        const r = checkArtifact(path);
        return [
          `文件: ${path}`,
          `编码: ${r.plaintext ? '明文 jsonl' : 'zstd'}`,
          `首帧契约: 满足（恰好一行 header）`,
          r.plaintext ? `行数: ${r.lines}` : `frame 数: ${r.frameCount}`,
          `会话 id: ${r.id}`,
          `格式版本: v${r.version}`,
          `cwd: ${r.cwd || '(无)'}`,
        ].join('\n');
      },
    },
    {
      name: 'session_migrate_list',
      description:
        '列出目标 DSH_HOME 下的全部会话（按 cwd 目录分组，显示各 generation 与磁盘版本），并暴露布局问题：' +
        'sessions/ 根下的非法裸目录会导致 DSH 报 unsupported flat-file layout、workspaceRegistry 激活失败，' +
        '表现为「工作区列表为空 + directoryPickerController is unavailable」。',
      parameters: normalizeParameters({ home: 'string?' }),
      render: textRender,
      execute: async ({ home }) => {
        const h = home || detectHome(null);
        if (!h) throw new Error('需要 home 或设置 DSH_HOME');
        const { projects, illegal } = listSessions(h);
        const lines = [`DSH_HOME: ${h}`, ''];
        for (const p of projects) {
          lines.push(`── ${p.dir}`);
          for (const s of p.sessions) {
            const gens = s.generations.map((g) => `${g.file}(v${g.version},${g.size}B)`).join('  ') || '(无 generation)';
            lines.push(`   ${s.id}`);
            lines.push(`      ${gens}`);
          }
        }
        if (illegal.length) {
          lines.push('', '⚠ 非法目录（会导致激活失败）:');
          for (const n of illegal) lines.push(`   ${n}`);
          lines.push('   → 运行 session_migrate_fix 移出');
        }
        return lines.join('\n');
      },
    },
    {
      name: 'session_migrate_fix',
      description:
        '修复布局：把 sessions/ 根下的非法裸目录移出到 <home>/../session-backups/（改名保留，可恢复）。' +
        '用于修复因备份放错位置而导致的 workspaceRegistry 激活失败。',
      parameters: normalizeParameters({ home: 'string?' }),
      render: textRender,
      execute: async ({ home }) => {
        const h = home || detectHome(null);
        if (!h) throw new Error('需要 home 或设置 DSH_HOME');
        const { moved } = fixLayout(h);
        return moved.length ? `已移出 ${moved.length} 项至 session-backups/` : '布局正常，无需修复';
      },
    },
    {
      name: 'session_migrate_import',
      description:
        '把会话导入目标 DSH_HOME（双路径：源 + 目标 home）。源可以是单个会话文件（zstd 或明文 jsonl），' +
        '也可以是导出包解出的目录（自动带上 subagents/*）。' +
        '明文会在导入时转成 zstd；header 的 cwd 会被改写成目标实例路径（否则 DSH 按 cwd 算目录名会找不到会话）；' +
        '导入后需启动 DSH 打开会话，由持久化层自动完成 v0→v1→v2→v3 迁移。' +
        '注意：本工具不启动/不停止 DSH，迁移应在 DSH 停止时执行。',
      parameters: normalizeParameters({
        source: 'string',
        home: 'string',
        cwd: 'string?',
      }),
      render: textRender,
      execute: async ({ source, home, cwd }) => {
        if (!source) throw new Error('需要 source');
        const h = home || detectHome(null);
        if (!h) throw new Error('需要 home 或设置 DSH_HOME');
        const r = importAuto({ src: source, home: h, targetCwd: cwd || null });
        return [
          `会话 id: ${r.sid}`,
          `源 cwd: ${r.srcCwd}`,
          `目标 cwd: ${r.targetCwd}`,
          `落盘: ${r.main.dir}  (${r.main.action})`,
          `子会话: ${r.subagents.filter((s) => s.ok).length}/${r.subagents.length} 成功`,
          '',
          '下一步：启动 DSH 并打开该会话，持久化层会自动跑 v0→v1→v2→v3。',
        ].join('\n');
      },
    },
  ];
}

/** 系统提示词：会话迁移的关键约定（同步返回） */
export const promptSection = {
  name: 'session-migrate',
  order: 900,
  text: () =>
    '【DSH 会话迁移约定】\n' +
    '· DSH 会话格式随版本演进（0.1.2 写 v0，0.1.5+ 为 v3）；官方无迁移命令，打开会话时持久化层自动沿 v0→v1→v2→v3 还原。\n' +
    '· 投放会话必须满足两项格式契约：\n' +
    '  1) sessions/ 根下只允许 --<cwd编码>-- 目录，裸目录会导致 workspaceRegistry 激活失败（工作区列表为空）。\n' +
    '  2) session.jsonl.zstd 首帧必须恰好一行 header；用 zstd 整体重压缩会合并帧并导致读取失败。\n' +
    '· 会话 header 的 cwd 必须指向目标实例的实际路径，否则按 cwd 推导的目录名对不上。\n' +
    '· 导入后需重新启动 DSH 并打开会话，迁移才发生；迁移产物是新的 session.v3.jsonl.zstd，源文件保留。',
};

/**
 * HTTP 处理器（供 webServer.register 使用）。
 * @param {object} req
 * @param {object} res
 * @param {string} rest 路径剩余部分
 */
export function handleHttp(req, res, rest, config) {
  const send = (code, obj) => {
    res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(obj, null, 2));
  };
  try {
    const home = detectHome(config);
    const path = (rest || '').replace(/^\//, '').split('?')[0];

    if (path === 'list' || path === '') {
      const { projects, illegal } = listSessions(home);
      return send(200, { home, projects, illegal });
    }
    if (path === 'check') {
      const u = new URL(req.url, 'http://x');
      const f = u.searchParams.get('path');
      if (!f) return send(400, { error: '需要 ?path=' });
      return send(200, checkArtifact(f));
    }
    if (path === 'fix') {
      return send(200, fixLayout(home));
    }
    return send(404, { error: `未知路径: ${path}` });
  } catch (e) {
    return send(500, { error: e.message });
  }
}

/**
 * DSH 插件入口（DSH 调用）。
 *
 * 注意（cordis 行为，踩过的坑）：
 *   · ctx.log / ctx.workspaceRoot 是 cordis 服务属性，**未 inject 时直读会抛**
 *     "cannot get property ... without inject" 导致插件树加载失败；一律用 ctx.get() 防御式读取。
 *   · defineTool 需从 @deepseek-ai/dsh-tools 动态加载；加载不到时只跳过工具注册。
 *
 * @param {object} ctx 插件上下文
 * @param {object} [config] 插件配置
 */
export async function apply(ctx, config = {}) {
  const log = (ctx?.get?.('log')?.info?.bind(ctx.get('log'))) || ((...a) => console.log('[session-migrate]', ...a));
  const tools = listTools();
  log(`[session-migrate] v${version} 接线开始（${tools.length} 个工具）`);

  // 1) 工具注册：ctx.inject(['tools']) → get('tools').register(defineTool(spec))
  const defineTool = await loadDefineTool(log);
  if (typeof ctx?.inject !== 'function') { log('[session-migrate] ctx.inject 不可用，跳过全部注册'); return; }
  if (typeof defineTool !== 'function') {
    log('[session-migrate] defineTool 不可用，工具未注册（CLI 仍可用：node cli.mjs）');
  } else {
    ctx.inject(['tools'], (tctx) => {
      const registry = tctx?.get?.('tools');
      if (!registry?.register) { log('[session-migrate] tools 服务不可用，工具未注册'); return; }
      let n = 0;
      for (const t of tools) {
        try { registry.register(defineTool(t)); n += 1; }
        catch (e) { log(`[session-migrate] 工具 ${t.name} 注册失败: ${e?.message || e}`); }
      }
      log(`[session-migrate] 已注册 ${n}/${tools.length} 个工具`);
    });
  }

  // 2) 系统提示词（text 必须是同步函数）
  ctx.inject(['systemPrompt'], (sctx) => {
    const sp = sctx?.get?.('systemPrompt');
    if (!sp?.section) { log('[session-migrate] systemPrompt 服务不可用，跳过注入'); return; }
    try { sp.section(promptSection); log('[session-migrate] 已注入会话迁移约定'); }
    catch (e) { log(`[session-migrate] 提示词注入失败: ${e?.message || e}`); }
  });

  // 3) HTTP API
  ctx.inject(['webServer'], (wctx) => {
    const ws = wctx?.get?.('webServer');
    if (!ws?.register) { log('[session-migrate] webServer 服务不可用，跳过 HTTP 注册'); return; }
    try {
      ws.register({
        kind: 'prefix',
        path: '/api/session-migrate',
        handler: (req, res, rest) => handleHttp(req, res, rest, config),
      });
      log('[session-migrate] 已注册 HTTP API: /api/session-migrate/*');
    } catch (e) {
      log(`[session-migrate] HTTP 注册失败: ${e?.message || e}`);
    }
  });
}
