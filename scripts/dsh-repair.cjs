#!/usr/bin/env node
/* 独立运行版 dsh-repair（从 start.sh 内嵌代码抽取，含 UID 隔离补丁）。
 * 用法（三选一）：
 *   node dsh-repair.cjs --dsh <DSH目录> --dsh-home <数据区> --home <HOME> [--dsh-port 30801 --proxy-port 30800 --container-port 30802]
 *   DSH_REPAIR_DIR=... DSH_REPAIR_HOME=... node dsh-repair.cjs
 *   node dsh-repair.cjs            # 自动扫描运行中 DSH 进程定位（脚本目录/同级优先）
 * start.sh 内嵌的是同一份逻辑（走环境变量），本文件为独立维护版。
 */
// ---- standalone CLI shim：把 --xxx 参数映射为 DSH_REPAIR_* 环境变量 ----
(function shim() {
  const argv = process.argv;
  const get = (name) => { const i = argv.indexOf(name); return i !== -1 && argv[i + 1] ? argv[i + 1] : undefined; };
  const map = [
    ['--dsh', 'DSH_REPAIR_DIR'],
    ['--dsh-home', 'DSH_REPAIR_HOME'],
    ['--home', 'DSH_REPAIR_HOME_PARENT'],
    ['--dsh-port', 'DSH_REPAIR_DSH_PORT'],
    ['--proxy-port', 'DSH_REPAIR_PROXY_PORT'],
    ['--container-port', 'DSH_REPAIR_CONTAINER_PORT'],
    ['--node', 'DSH_REPAIR_NODE'],
    ['--entry', 'DSH_REPAIR_ENTRY'],
  ];
  for (const [flag, env] of map) {
    const v = get(flag);
    if (v !== undefined && process.env[env] === undefined) process.env[env] = v;
  }
  if (!process.env.DSH_REPAIR_PID_FILE) {
    const uid = typeof process.getuid === 'function' && process.getuid() !== undefined ? process.getuid() : 'x';
    process.env.DSH_REPAIR_PID_FILE = `/tmp/dsh-repair-${uid}.pid`;
  }
  if (get('--tsx') !== undefined) process.env.DSH_REPAIR_TSX = '1';
})();

'use strict';
const { spawn, execSync } = require('child_process');
const fs = require('fs');
const http = require('http');
const net = require('net');

const dshDir = process.env.DSH_REPAIR_DIR;
const dshHome = process.env.DSH_REPAIR_HOME;
const home = process.env.DSH_REPAIR_HOME_PARENT;
const nodeBin = process.env.DSH_REPAIR_NODE;
const entry = process.env.DSH_REPAIR_ENTRY;
const tsx = process.env.DSH_REPAIR_TSX === '1';
const dshPort = parseInt(process.env.DSH_REPAIR_DSH_PORT || '30801', 10);
const proxyPort = parseInt(process.env.DSH_REPAIR_PROXY_PORT || '30800', 10);
const containerPort = parseInt(process.env.DSH_REPAIR_CONTAINER_PORT || '30802', 10);
const PID_FILE = process.env.DSH_REPAIR_PID_FILE;

function writeTmpFile(file, content) {
  try {
    fs.writeFileSync(file, content, 'utf-8');
    return;
  } catch (err) {
    const code = err && err.code;
    if (code !== 'EACCES' && code !== 'EPERM') throw err;
  }
  try { fs.unlinkSync(file); } catch {}
  fs.writeFileSync(file, content, 'utf-8');
}

// 权限修复（尽力而为；非属主时 EPERM 仅警告）
function secureDshTree(dir) {
  console.log(`[√] 收紧权限: ${dir}`);
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dir, 0o700);
    const walk = (d) => {
      let entries;
      try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
      for (const ent of entries) {
        if (ent.name === '.' || ent.name === '..') continue;
        const p = require('path').join(d, ent.name);
        try {
          if (ent.isSymbolicLink()) continue;
          if (ent.isDirectory()) { fs.chmodSync(p, 0o700); walk(p); }
          else { fs.chmodSync(p, 0o600); }
        } catch {}
      }
    };
    walk(dir);
  } catch (error) {
    console.error(`[!] 权限修复警告: ${error.message}`);
  }
}

async function isPortInUse(port) {
  return new Promise(resolve => {
    const s = net.connect(port, '127.0.0.1');
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('error', () => resolve(false));
  });
}

function killOldProcesses() {
  try {
    const oldPid = fs.readFileSync(PID_FILE, 'utf-8').trim();
    if (oldPid && String(oldPid) !== String(process.pid)) {
      console.log(`[√] 停止旧实例 (PID ${oldPid})`);
      try { process.kill(parseInt(oldPid, 10), 'SIGTERM'); } catch {}
      try { process.kill(parseInt(oldPid, 10), 'SIGKILL'); } catch {}
    }
  } catch {}
  try {
    const out = execSync(
      "ps -eo pid,args | grep -E 'bin\\.ts web|bin\\.js web' | grep -v grep | awk '{print $1}'",
      { encoding: 'utf8' }
    );
    for (const pid of out.trim().split('\n').filter(Boolean)) {
      try {
        const cwd = fs.readlinkSync(require('path').join('/proc', pid, 'cwd'));
        if (cwd === dshDir) {
          console.log(`[√] 停止 DSH 子进程 (PID ${pid})`);
          process.kill(parseInt(pid, 10), 'SIGKILL');
        }
      } catch {}
    }
  } catch {}
  return new Promise(resolve => setTimeout(resolve, 2000));
}

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

function buildContainerHtml() {
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

async function main() {
  console.log('═══════════════════════════════════════');
  console.log('  DSH 修复/守护（内嵌于 start.sh）');
  console.log('═══════════════════════════════════════');
  console.log(`[√] DSH 目录: ${dshDir}`);
  console.log(`[√] 启动入口: ${entry} (tsx=${tsx})`);
  console.log(`[√] Node: ${nodeBin}`);
  console.log(`[√] DSH_HOME: ${dshHome}`);

  await killOldProcesses();
  writeTmpFile(PID_FILE, String(process.pid));

  try { fs.mkdirSync(dshHome, { recursive: true, mode: 0o700 }); } catch (e) { console.error(`[!] mkdir DSH_HOME: ${e.message}`); }
  try { fs.mkdirSync(home, { recursive: true, mode: 0o700 }); } catch (e) {}
  secureDshTree(dshHome);

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

  console.log(`[>] 启动 DSH (127.0.0.1:${dshPort})`);
  const dshArgs = tsx
    ? ['--import', 'tsx/esm', entry, 'web', '--host', '127.0.0.1', '--port', String(dshPort), '--no-open']
    : [entry, 'web', '--host', '127.0.0.1', '--port', String(dshPort), '--no-open'];

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

  await new Promise(r => setTimeout(r, 3000));

  const polyfill = buildPolyfillScript();
  const proxyServer = http.createServer((clientReq, clientRes) => {
    // 不设置 x-forwarded-for / x-real-ip / forwarded：
    // 插件的重启接口要求 "loopback 直连且无代理转发痕迹"（trustedRestartRequest）
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

  const containerHtml = buildContainerHtml();
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

  let tokenWait = 0;
  while (!dshToken && tokenWait < 40) {
    await new Promise(r => setTimeout(r, 500));
    tokenWait++;
  }

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
