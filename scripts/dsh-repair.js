#!/usr/bin/env node
/**
 * DSH 全自动修复脚本
 * 功能：扫描 DSH 目录 → 权限修复 → 启动 DSH（runner 模式）→ 反代 + 容器页面
 * 定位通道（按优先级）：
 *   1. --dsh <path> 参数
 *   2. 脚本所在目录搜索（默认，脚本放在 DSH 同级）
 *   3. 扫描运行中 DSH 进程（/proc/<pid>/cwd + environ）
 * 端口：DSH=30801, PROXY=30800, CONTAINER=30802（可 --dsh-port 覆盖）
 */
'use strict';

const { spawn, execSync } = require('child_process');
const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');

// ========== 配置 ==========
const DEFAULT_DSH_PORT = 30801;
const DEFAULT_PROXY_PORT = 30800;
const DEFAULT_CONTAINER_PORT = 30802;
const PID_FILE = '/tmp/dsh-repair.pid';
const RUNNER_LOG = '/tmp/dsh-repair-runner.log';
const CONTAINER_LOG = '/tmp/dsh-repair-container.log';

// ========== 1. 定位 DSH 目录 ==========
function findDshDir() {
  // ① 参数
  const argIdx = process.argv.indexOf('--dsh');
  if (argIdx !== -1 && process.argv[argIdx + 1]) {
    const d = path.resolve(process.argv[argIdx + 1]);
    if (isDshDir(d)) return d;
    console.error(`[!] 参数 --dsh 指定的路径不是 DSH 目录: ${d}`);
    process.exit(1);
  }

  // ② 脚本所在目录 / 同级子目录
  const scriptDir = __dirname;
  if (isDshDir(scriptDir)) return scriptDir;
  try {
    for (const ent of fs.readdirSync(scriptDir, { withFileTypes: true })) {
      if (!ent.isDirectory() || ent.name.startsWith('.')) continue;
      const p = path.join(scriptDir, ent.name);
      if (isDshDir(p)) return p;
    }
  } catch {}

  // ③ 扫描运行中 DSH 进程
  const procDir = '/proc';
  try {
    for (const pid of fs.readdirSync(procDir)) {
      if (!/^\d+$/.test(pid)) continue;
      try {
        const cmdline = fs.readFileSync(path.join(procDir, pid, 'cmdline'), 'utf-8').replace(/\0/g, ' ');
        if (!cmdline.includes('bin.ts web') && !cmdline.includes('bin.js web') && !cmdline.includes('dsh web')) continue;
        if (cmdline.includes('-port') || cmdline.includes('--port')) {
          const cwd = fs.readlinkSync(path.join(procDir, pid, 'cwd'));
          if (isDshDir(cwd)) return cwd;
        }
      } catch {}
    }
  } catch {}

  console.error('[!] 未找到 DSH 目录。尝试：\n' +
    '  1. 将脚本放到 DSH 目录同级\n' +
    '  2. node dsh-repair.js --dsh <DSH目录>\n' +
    '  3. 先启动 DSH 再运行脚本（自动扫进程）');
  process.exit(1);
}

function isDshDir(dir) {
  if (!dir) return false;
  try {
    return fs.existsSync(path.join(dir, 'apps/cli/src/bin.ts')) ||
           fs.existsSync(path.join(dir, 'lib/bin.js')) ||
           fs.existsSync(path.join(dir, 'node_modules/@deepseek-ai/dsh/lib/bin.js')) ||
           fs.existsSync(path.join(dir, 'apps/cli/package.json'));
  } catch { return false; }
}

// ========== 2. 检测 DSH 入口和 node ==========
function detectEntry(dshDir) {
  const checks = [
    { entry: 'apps/cli/src/bin.ts',          tsx: true,  exists: 'apps/cli/src/bin.ts' },
    { entry: 'node_modules/@deepseek-ai/dsh/lib/bin.js', tsx: false, exists: 'node_modules/@deepseek-ai/dsh/lib/bin.js' },
    { entry: 'lib/bin.js',                    tsx: false, exists: 'lib/bin.js' },
    { entry: 'apps/cli/lib/bin.js',           tsx: false, exists: 'apps/cli/lib/bin.js' },
  ];
  for (const c of checks) {
    if (fs.existsSync(path.join(dshDir, c.exists))) return c;
  }
  throw new Error('未找到 DSH 启动入口（apps/cli/src/bin.ts / lib/bin.js）');
}

function findNode() {
  const cands = [
    '/vol1/@appcenter/nodejs_v24/bin/node',
    '/vol1/@appcenter/deepseek-harness-nas/bin/node',
    '/usr/local/bin/node',
    '/usr/bin/node',
  ];
  for (const c of cands) if (fs.existsSync(c)) return c;
  try {
    const out = execSync('command -v node 2>/dev/null || which node 2>/dev/null', { encoding: 'utf8' }).trim();
    if (out) return out;
  } catch {}
  throw new Error('未找到 node 可执行文件');
}

// ========== 3. 探测 DSH_HOME 和数据区 ==========
function resolveDshHome(dshDir) {
  // 优先：从进程 environ 读取（cwd 必须匹配 dshDir，防止扫到其他实例）
  try {
    const procDir = '/proc';
    for (const pid of fs.readdirSync(procDir)) {
      if (!/^\d+$/.test(pid)) continue;
      try {
        const cmdline = fs.readFileSync(path.join(procDir, pid, 'cmdline'), 'utf-8').replace(/\0/g, ' ');
        if (!cmdline.includes('bin.ts web') && !cmdline.includes('bin.js web')) continue;
        // 只匹配 cwd 与 dshDir 一致的进程（避免误扫其他实例）
        const cwd = fs.readlinkSync(path.join(procDir, pid, 'cwd'));
        if (cwd !== dshDir) continue;
        const environ = fs.readFileSync(path.join(procDir, pid, 'environ'), 'utf-8').split('\0');
        for (const env of environ) {
          if (env.startsWith('DSH_HOME=')) {
            const dshHome = env.slice('DSH_HOME='.length);
            if (fs.existsSync(dshHome)) {
              const homeEnv = environ.find(e => e.startsWith('HOME='));
              const home = homeEnv ? homeEnv.slice('HOME='.length) : path.dirname(dshHome);
              console.log(`[√] 从进程 ${pid} 探测到 DSH_HOME=${dshHome}`);
              return { dshHome, home };
            }
          }
        }
      } catch {}
    }
  } catch {}

  // 默认：按标准路径推断
  const runDotDsh = path.join(dshDir, '.dsh-home', 'run', '.dsh');
  const runDir = path.join(dshDir, '.dsh-home', 'run');
  if (fs.existsSync(runDotDsh)) return { dshHome: runDotDsh, home: runDir };
  const dshDirDotDsh = path.join(dshDir, '.dsh');
  if (fs.existsSync(dshDirDotDsh) && fs.statSync(dshDirDotDsh).isDirectory()) {
    return { dshHome: dshDirDotDsh, home: dshDir };
  }
  // 不存在则创建 .dsh-home/run/.dsh
  fs.mkdirSync(runDotDsh, { recursive: true, mode: 0o700 });
  fs.mkdirSync(runDir, { recursive: true, mode: 0o700 });
  return { dshHome: runDotDsh, home: runDir };
}

// ========== 4. 权限修复（secureDshTree） ==========
function secureDshTree(dshHome) {
  console.log(`[√] 收紧权限: ${dshHome}`);
  try {
    fs.mkdirSync(dshHome, { recursive: true, mode: 0o700 });
    fs.chmodSync(dshHome, 0o700);
    const walk = (dir) => {
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const ent of entries) {
        if (ent.name === '.' || ent.name === '..') continue;
        const p = path.join(dir, ent.name);
        try {
          if (ent.isSymbolicLink()) continue;
          if (ent.isDirectory()) { fs.chmodSync(p, 0o700); walk(p); }
          else { fs.chmodSync(p, 0o600); }
        } catch {}
      }
    };
    walk(dshHome);
  } catch (error) {
    console.error(`[!] 权限修复警告: ${error.message}`);
  }
}

// ========== 5. 端口选择 ==========
function parsePortArg(name, defaultVal) {
  const idx = process.argv.indexOf(name);
  if (idx !== -1 && process.argv[idx + 1]) {
    const p = parseInt(process.argv[idx + 1], 10);
    if (p > 0 && p < 65536) return p;
    console.error(`[!] 无效端口: ${process.argv[idx + 1]}`);
  }
  return defaultVal;
}

async function isPortInUse(port) {
  return new Promise(resolve => {
    const s = net.connect(port, '127.0.0.1');
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('error', () => resolve(false));
  });
}

// ========== 6. 停止旧进程 ==========
function killOldProcesses(dshDir) {
  // 读取 PID 文件（旧 runner）
  try {
    const oldPid = fs.readFileSync(PID_FILE, 'utf-8').trim();
    if (oldPid) {
      console.log(`[√] 停止旧实例 (PID ${oldPid})`);
      try { process.kill(parseInt(oldPid, 10), 'SIGTERM'); } catch {}
      try { process.kill(parseInt(oldPid, 10), 'SIGKILL'); } catch {}
    }
  } catch {}
  // 杀掉 cwd 匹配 dshDir 的 DSH web 进程（防孤儿占端口）
  if (dshDir) {
    try {
      const out = execSync(
        "ps -eo pid,args | grep -E 'bin\\.ts web|bin\\.js web' | grep -v grep | awk '{print $1}'",
        { encoding: 'utf8' }
      );
      for (const pid of out.trim().split('\n').filter(Boolean)) {
        try {
          const cwd = fs.readlinkSync(path.join('/proc', pid, 'cwd'));
          if (cwd === dshDir) {
            console.log(`[√] 停止 DSH 子进程 (PID ${pid})`);
            process.kill(parseInt(pid, 10), 'SIGKILL');
          }
        } catch {}
      }
    } catch {}
  }
  // 额外清理：匹配脚本特征的 node 进程（排除自身与 shell）
  const selfPid = String(process.pid);
  try {
    const out = execSync(
      "ps -eo pid,args | grep 'dsh-repair' | grep -v grep | awk '{print $1, $2}' | grep 'node' | awk '{print $1}'",
      { encoding: 'utf8' }
    );
    for (const pid of out.trim().split('\n').filter(Boolean)) {
      if (pid === selfPid) continue;
      try { process.kill(parseInt(pid, 10), 'SIGTERM'); } catch {}
    }
  } catch {}
  // 等待端口释放
  return new Promise(resolve => setTimeout(resolve, 2000));
}

// ========== 7. Polyfill 脚本 ==========
function buildPolyfillScript() {
  return `<script>
(function() {
  // ownsHost 声明：使 isLoopback=true → persistence='host' → settings 可用
  try {
    var g = typeof globalThis !== 'undefined' ? globalThis : typeof window !== 'undefined' ? window : typeof self !== 'undefined' ? self : this;
    if (!g.__DSH_TRANSPORT__) { try { g.__DSH_TRANSPORT__ = {}; } catch(e){} }
    if (g.__DSH_TRANSPORT__) {
      try { Object.defineProperty(g.__DSH_TRANSPORT__, 'ownsHost', { value: true, writable: false, configurable: false }); }
      catch(e) { g.__DSH_TRANSPORT__.ownsHost = true; }
    }
  } catch(e) { console.warn('[DSH] ownsHost:', e); }
  // crypto.randomUUID polyfill（非安全上下文局域网修复）
  function createUUID() {
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      return '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, function(c) {
        return (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16);
      });
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
      var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }
  try {
    var g = typeof globalThis !== 'undefined' ? globalThis : typeof window !== 'undefined' ? window : typeof self !== 'undefined' ? self : this;
    if (!g.crypto) { try { g.crypto = {}; } catch(e){} }
    if (g.crypto) {
      try { if (!g.crypto.randomUUID) { Object.defineProperty(g.crypto, 'randomUUID', { value: createUUID, writable: true, configurable: true, enumerable: true }); } }
      catch(e) { g.crypto.randomUUID = createUUID; }
    }
  } catch(e) { console.warn('[DSH] randomUUID:', e); }
})();
</script>`;
}

// ========== 8. 容器页面 HTML ==========
function buildContainerHtml(proxyPort) {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DSH 容器</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:100%;height:100%;overflow:hidden;background:#000}
iframe{width:100%;height:100%;border:none}
</style>
</head>
<body>
<script>
// 统一走反代（带 polyfill + ownsHost）
var host = window.location.hostname;
document.write('<iframe src="http://' + host + ':' + ${proxyPort} + '/" id="dshFrame"></iframe>');
</script>
</body>
</html>`;
}

// ========== 9. 主流程 ==========
async function main() {
  console.log('═══════════════════════════════════════');
  console.log('  DSH 全自动修复脚本');
  console.log('═══════════════════════════════════════');

  // 定位 DSH 目录（先定位，killOldProcesses 需要它来清理孤儿 DSH 进程）
  const dshDir = findDshDir();
  console.log(`[√] DSH 目录: ${dshDir}`);

  // 先停止旧实例（必须在自己写 PID 文件之前，否则会 kill 自己）
  await killOldProcesses(dshDir);
  // 再写入本实例 PID
  fs.writeFileSync(PID_FILE, String(process.pid), 'utf-8');

  // 检测入口
  const entryInfo = detectEntry(dshDir);
  console.log(`[√] 启动入口: ${entryInfo.entry} (tsx=${entryInfo.tsx})`);

  // 找 node
  const nodeBin = findNode();
  console.log(`[√] Node: ${nodeBin}`);

  // 探测 DSH_HOME
  const { dshHome, home } = resolveDshHome(dshDir);
  console.log(`[√] DSH_HOME: ${dshHome}`);
  console.log(`[√] HOME: ${home}`);

  // 权限修复
  secureDshTree(dshHome);

  // 端口
  const dshPort = parsePortArg('--dsh-port', DEFAULT_DSH_PORT);
  const proxyPort = parsePortArg('--proxy-port', DEFAULT_PROXY_PORT);
  const containerPort = parsePortArg('--container-port', DEFAULT_CONTAINER_PORT);

  // 等端口释放
  let waitCount = 0;
  while (waitCount < 10) {
    const d = await isPortInUse(dshPort);
    const p = await isPortInUse(proxyPort);
    const c = await isPortInUse(containerPort);
    if (!d && !p && !c) break;
    await new Promise(r => setTimeout(r, 500));
    waitCount++;
  }
  console.log(`[√] 端口: DSH=${dshPort}, 反代=${proxyPort}, 容器=${containerPort}`);

  // ========== 启动 DSH ==========
  console.log(`[>] 启动 DSH (127.0.0.1:${dshPort})`);
  const dshArgs = entryInfo.tsx
    ? ['--import', 'tsx/esm', entryInfo.entry, 'web', '--host', '127.0.0.1', '--port', String(dshPort), '--no-open']
    : [entryInfo.entry, 'web', '--host', '127.0.0.1', '--port', String(dshPort), '--no-open'];

  const dshProcess = spawn(nodeBin, dshArgs, {
    cwd: dshDir,
    env: { ...process.env, DSH_HOME: dshHome, HOME: home },
    stdio: ['ignore', 'pipe', 'inherit'],
  });

  let dshToken = '';
  dshProcess.stdout.on('data', (chunk) => {
    const s = chunk.toString();
    process.stdout.write(s);
    const m = s.match(/token=([A-Za-z0-9_-]+)/);
    if (m) dshToken = m[1];
  });

  dshProcess.on('exit', (code, sig) => {
    console.log(`[!] DSH 退出 code=${code} signal=${sig}`);
    setTimeout(() => process.exit(code || 0), 1000);
  });

  // 等 DSH 启动
  await new Promise(r => setTimeout(r, 3000));

  // ========== 启动反代 ==========
  const polyfill = buildPolyfillScript();
  const proxyServer = http.createServer((clientReq, clientRes) => {
    // 不设置 x-forwarded-for / x-real-ip / forwarded：
    // dsh-market 等插件的重启接口要求"loopback 直连且无代理转发痕迹"
    // （trustedRestartRequest），带这些头会被判定为代理转发而拒绝。
    const headers = {
      ...clientReq.headers,
      'x-forwarded-proto': 'http',
      'x-forwarded-host': clientReq.headers.host || `0.0.0.0:${proxyPort}`,
      host: `127.0.0.1:${dshPort}`,
    };
    delete headers['x-forwarded-for'];
    delete headers['x-real-ip'];
    delete headers.forwarded;
    if (clientReq.headers.origin) headers.origin = `http://127.0.0.1:${dshPort}`;
    if (clientReq.headers.referer) headers.referer = `http://127.0.0.1:${dshPort}/`;
    if (headers['sec-fetch-site'] === 'cross-site') headers['sec-fetch-site'] = 'same-origin';
    const isHtml = clientReq.url === '/' || clientReq.url.endsWith('.html') || !clientReq.url.includes('.');
    if (isHtml) delete headers['accept-encoding'];

    const options = { hostname: '127.0.0.1', port: dshPort, path: clientReq.url, method: clientReq.method, headers };
    const proxyReq = http.request(options, (proxyRes) => {
      const isHtmlResp = (proxyRes.headers['content-type'] || '').includes('text/html');
      if (isHtmlResp) {
        let chunks = [];
        proxyRes.on('data', chunk => chunks.push(chunk));
        proxyRes.on('end', () => {
          let body = Buffer.concat(chunks).toString('utf-8');
          if (body.includes('<head>')) body = body.replace('<head>', `<head>${polyfill}`);
          else body = polyfill + body;
          const resHeaders = { ...proxyRes.headers };
          delete resHeaders['content-length'];
          resHeaders['content-length'] = Buffer.byteLength(body, 'utf-8');
          resHeaders['cache-control'] = 'no-store, no-cache, must-revalidate';
          resHeaders['pragma'] = 'no-cache';
          clientRes.writeHead(proxyRes.statusCode, resHeaders);
          clientRes.end(body);
        });
      } else {
        const resHeaders = { ...proxyRes.headers };
        resHeaders['cache-control'] = 'no-store, no-cache, must-revalidate';
        resHeaders['pragma'] = 'no-cache';
        clientRes.writeHead(proxyRes.statusCode, resHeaders);
        proxyRes.pipe(clientRes, { end: true });
      }
    });
    proxyReq.on('error', () => {
      if (!clientRes.headersSent) {
        clientRes.writeHead(502, { 'Content-Type': 'text/html; charset=utf-8' });
        clientRes.end('<h3>DSH 正在启动中，请稍候刷新...</h3>');
      }
    });
    clientReq.pipe(proxyReq, { end: true });
  });

  proxyServer.on('upgrade', (req, socket, head) => {
    const headers = { ...req.headers, host: `127.0.0.1:${dshPort}` };
    if (headers.origin) headers.origin = `http://127.0.0.1:${dshPort}`;
    if (headers['sec-fetch-site'] === 'cross-site') headers['sec-fetch-site'] = 'same-origin';
    const proxySocket = net.connect(dshPort, '127.0.0.1', () => {
      proxySocket.write(`${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
        Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') + '\r\n\r\n');
      if (head && head.length) proxySocket.write(head);
      socket.pipe(proxySocket); proxySocket.pipe(socket);
    });
    proxySocket.on('error', () => socket.destroy());
    socket.on('error', () => proxySocket.destroy());
  });

  proxyServer.listen(proxyPort, '0.0.0.0', () => {
    console.log(`[√] 反代: http://0.0.0.0:${proxyPort} -> http://127.0.0.1:${dshPort}`);
  });

  // ========== 启动容器页面 ==========
  const containerHtml = buildContainerHtml(proxyPort);
  const containerServer = http.createServer((req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      'Pragma': 'no-cache',
    });
    res.end(containerHtml);
  });
  containerServer.listen(containerPort, '0.0.0.0', () => {
    console.log(`[√] 容器: http://0.0.0.0:${containerPort}/`);
  });

  // 等 DSH 输出 token（最多 8 秒）
  let tokenWait = 0;
  while (!dshToken && tokenWait < 16) {
    await new Promise(r => setTimeout(r, 500));
    tokenWait++;
  }

  // ========== 输出访问信息 ==========
  console.log('═══════════════════════════════════════');
  console.log('  DSH 修复完成');
  console.log('═══════════════════════════════════════');
  if (dshToken) {
    console.log(`  首次认证: http://127.0.0.1:${dshPort}/?token=${dshToken}`);
    console.log(`  首次认证: http://<NAS-IP>:${proxyPort}/?token=${dshToken}`);
    console.log('');
  }
  console.log(`  认证后访问: http://<NAS-IP>:${proxyPort}/`);
  console.log(`  容器页面: http://<NAS-IP>:${containerPort}/`);
  console.log('═══════════════════════════════════════');

  // ========== 优雅退出 ==========
  function shutdown(signal) {
    console.log(`\n[!] 收到 ${signal}，正在停止...`);
    try { fs.unlinkSync(PID_FILE); } catch {}
    try { if (dshProcess && !dshProcess.killed) dshProcess.kill('SIGKILL'); } catch {}
    try { proxyServer.close(); } catch {}
    try { containerServer.close(); } catch {}
    process.exit(0);
  }
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGHUP', () => shutdown('SIGHUP'));
}

main().catch(err => {
  console.error('[!] 修复失败:', err.message);
  try { fs.unlinkSync(PID_FILE); } catch {}
  process.exit(1);
});