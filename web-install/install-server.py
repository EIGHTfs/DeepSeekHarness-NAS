#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DeepSeekHarness-NAS 安装工具服务端（网页直调远程脚本版）
- GET  /                      前端页面（install.html / install-fpk.html）
- GET  /api/config            读取已保存的配置（工作区根 install-config.json）
- POST /api/save              保存配置（工作区根 install-config.json）
- POST /api/detect            远程探测系统类型（群晖 DSM / 飞牛 fnOS）→ spk/fpk
- POST /api/run               后台执行远程脚本（install / uninstall / check）
- GET  /api/run-status        轮询后台任务状态与输出
- GET  /api/tasks             历史任务（兼容旧版）
- POST /api/build             触发本地构建（common / spk / fpk）
- POST /api/publish           发布包到 GitHub Release
纯标准库，无需 pip 依赖。sshpass 需本机已安装。
"""
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WS_ROOT = os.path.dirname(BASE_DIR)
CONFIG_FILE = os.path.join(WS_ROOT, 'install-config.json')   # 与 install-remote-spk.sh 同源！
TASKS_FILE = os.path.join(WS_ROOT, 'install-tasks.jsonl')
LOG_FILE = os.path.join(WS_ROOT, 'install-server.log')
HTML_FILE = os.path.join(BASE_DIR, 'install.html')
HTML_FILE_LEGACY = os.path.join(BASE_DIR, 'install-fpk.html')
SCRIPT = os.path.join(BASE_DIR, 'install-remote-spk.sh')
PORT = int(os.environ.get('INSTALL_SERVER_PORT', '8765'))
SSHPASS = os.environ.get('SSHPASS_BIN', 'sshpass')

# GitHub Release 自动发布配置
GITHUB_TOKEN_PATHS = [
    os.path.expanduser('~/.dsh/git-push/github-token'),
    os.path.join(WS_ROOT, '.dsh-home/.dsh/git-push/github-token'),
]
GITHUB_REPO = 'EIGHTfs/DeepSeekHarness-NAS'
GITHUB_API = 'https://api.github.com'


def log(msg):
    """写日志到 install-server.log（追加，带时间戳）"""
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write('[%s] %s\n' % (ts, msg))
    except Exception:
        pass


def file_md5(path):
    """本地计算包文件 MD5（历史记录用；大包流式读，不整载入内存）"""
    import hashlib
    h = hashlib.md5()
    try:
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1048576), b''):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ''


def _read_github_token():
    """读取 GitHub token（优先环境变量，其次 git-push 凭据文件）。"""
    tok = os.environ.get('GITHUB_TOKEN', '').strip()
    if tok:
        return tok
    for p in GITHUB_TOKEN_PATHS:
        if os.path.isfile(p):
            try:
                with open(p, 'r') as f:
                    tok = f.read().strip()
                if tok:
                    return tok
            except Exception:
                pass
    return ''


def _github_api(method, path, token, data=None, headers=None):
    """调用 GitHub API，返回 (status_code, response_body_dict)。"""
    url = '%s%s' % (GITHUB_API, path)
    hdrs = {
        'Authorization': 'token %s' % token,
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'dsh-install-server',
    }
    if headers:
        hdrs.update(headers)
    body = json.dumps(data).encode('utf-8') if data else None
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace')
        try:
            body = json.loads(body)
        except Exception:
            pass
        return e.code, body
    except Exception as e:
        return 0, {'message': str(e)}


def _upload_release_asset(upload_url, token, filepath, name):
    """上传文件到 GitHub Release asset。upload_url 形如 ...{?name,label}。"""
    url = upload_url.split('{')[0] + '?name=' + urllib.request.quote(name)
    with open(filepath, 'rb') as f:
        file_data = f.read()
    req = urllib.request.Request(url, data=file_data, method='POST', headers={
        'Authorization': 'token %s' % token,
        'Content-Type': 'application/octet-stream',
        'User-Agent': 'dsh-install-server',
    })
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace')
        return e.code, body
    except Exception as e:
        return 0, {'message': str(e)}


def publish_package_to_github(file_path, tag):
    """将指定包文件发布到 GitHub Release。
    1. 将文件复制到 release/<tag>/ 目录
    2. 调 GitHub API 创建/更新 Release 并上传资产
    返回 (success, message)。"""
    token = _read_github_token()
    if not token:
        return False, '未找到 GitHub Token'

    if not os.path.isfile(file_path):
        return False, '文件不存在: %s' % file_path

    fname = os.path.basename(file_path)
    release_dir = os.path.join(WS_ROOT, 'release', tag)

    # 复制到 release/<tag>/（如果文件已在该目录则跳过）
    os.makedirs(release_dir, exist_ok=True)
    dst = os.path.join(release_dir, fname)
    if os.path.abspath(file_path) != os.path.abspath(dst):
        import shutil
        try:
            shutil.copy2(file_path, dst)
            log('RELEASE copy %s -> %s' % (fname, release_dir))
        except Exception as e:
            log('RELEASE copy failed: %s' % e)
            return False, '复制产物失败: %s' % e

    # GitHub API: 获取或创建 Release
    status, rel = _github_api('GET', '/repos/%s/releases/tags/%s' % (GITHUB_REPO, tag), token)
    if status == 404:
        status, rel = _github_api('POST', '/repos/%s/releases' % GITHUB_REPO, token, {
            'tag_name': tag,
            'name': 'Release %s' % tag,
            'body': 'Published via install-server.py\nVersion: %s' % tag.lstrip('v'),
            'draft': False,
            'prerelease': '-' in tag,
        })
        if status not in (200, 201):
            return False, '创建 Release 失败: %s' % rel
        log('RELEASE created %s (id=%s)' % (tag, rel.get('id')))
    elif status == 200:
        log('RELEASE found %s (id=%s)' % (tag, rel.get('id')))
    else:
        return False, '查询 Release 失败: %s' % rel

    upload_url = rel.get('upload_url', '')
    if not upload_url:
        return False, 'Release 缺少 upload_url'

    # 检查同名 asset 是否已存在
    existing_assets = rel.get('assets', [])
    for a in existing_assets:
        if a.get('name') == fname:
            log('RELEASE asset already exists: %s (id=%s), deleting old' % (fname, a.get('id')))
            _github_api('DELETE', '/repos/%s/releases/assets/%s' % (GITHUB_REPO, a['id']), token)

    # 上传
    fsize = os.path.getsize(dst)
    log('RELEASE upload %s (%.1f MB)' % (fname, fsize / 1048576.0))
    status, resp = _upload_release_asset(upload_url, token, dst, fname)
    if status in (200, 201):
        log('RELEASE upload OK: %s' % fname)
        return True, '✅ 已发布 %s 到 %s' % (fname, tag)
    else:
        log('RELEASE upload FAILED: %s -> %s' % (fname, resp))
        return False, '上传失败: %s' % resp


def _find_package_file(package_name):
    """在 staging 和 release 目录中查找包文件，返回绝对路径或空字符串。"""
    # 先查 staging
    staging = os.path.join(WS_ROOT, 'build', 'staging', package_name)
    if os.path.isfile(staging):
        return staging
    # 再查 release（递归）
    release_root = os.path.join(WS_ROOT, 'release')
    if os.path.isdir(release_root):
        for dirpath, _, filenames in os.walk(release_root):
            if package_name in filenames:
                return os.path.join(dirpath, package_name)
    return ''


def extract_version(name):
    """从包文件名提取版本号（如 DeepSeekHarness-NAS_x86-0.1.5-rc.2.fpk → 0.1.5-rc.2）。
    先去掉包扩展名（.fpk/.spk），避免把后缀并进版本号。"""
    base = os.path.splitext(name)[0]
    m = re.search(r'(\d+\.\d+\.\d+(?:[-+][\w.]+)?)', base)
    return m.group(1) if m else ''


def record_task(cmd, spk, system, exit_code, status, run_id='', note=''):
    """安装历史落盘（install-tasks.jsonl，一行一任务）。
    内容：时间/命令/包名/版本/MD5/系统/退出码/结果/备注——不包含任何账号设备凭据（密码绝不下落盘）。"""
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    name = os.path.basename(spk) if spk else ''
    rec = {
        'ts': ts, 'cmd': cmd, 'package': name,
        'version': extract_version(name),
        'md5': file_md5(spk) if spk and os.path.isfile(spk) else '',
        'system': system, 'exit_code': exit_code,
        'status': status, 'run_id': run_id, 'note': note or '',
    }
    try:
        with open(TASKS_FILE, 'a', encoding='utf-8') as f:
            f.write(json.dumps(rec, ensure_ascii=False) + '\n')
        return True
    except Exception as e:
        log('HISTORY 写入失败: %s' % e)
        return False

# 后台运行任务表：run_id -> {status, output, exit_code, started, finished}
RUNS = {}
RUNS_LOCK = threading.Lock()

# ── 自动构建任务表（串行队列，同时间只跑一个） ──
BUILDS = {}
BUILDS_LOCK = threading.Lock()
BUILD_LOG_LINES = 200

# 阶段关键词 → (阶段名, 进度百分比)
# 含 build-common / build-spk / build-fpk 三个脚本的输出关键词
_BUILD_STAGES = [
    # build-common 阶段
    ('复制源码到构建副本', 8),
    ('pnpm install', 15),
    ('install 结束', 40),
    ('pnpm build', 45),
    ('build 结束', 68),
    ('组装 target', 72),
    ('裁剪', 78),
    ('target 预编译完成', 100),
    # build-spk 阶段
    ('SPK 打包', 10),
    ('SPK 端口', 15),
    ('打包 package.tgz', 30),
    ('组装外层 SPK', 60),
    ('✅ SPK:', 85),
    ('SPK 构建完成', 100),
    # build-fpk 阶段
    ('FPK 打包', 10),
    ('打包 app.tgz', 30),
    ('组装外层 FPK', 60),
    ('✅ FPK:', 85),
    ('FPK 构建完成', 100),
]

# 三个构建脚本（2026-09-15 目录归位后路径：SPK/FPK 子目录 + 通用留根）
_BUILD_SCRIPTS = {
    'common': 'build/build-common.sh',
    'spk':    'build/SPK/build-spk.sh',
    'fpk':    'build/FPK/build-fpk.sh',
}


def start_build(step='common'):
    """后台执行构建脚本。返回 (build_id, error_msg)。"""
    script_rel = _BUILD_SCRIPTS.get(step)
    if not script_rel:
        return None, 'step 必须是 common|spk|fpk'
    script_abs = os.path.join(WS_ROOT, script_rel)
    if not os.path.isfile(script_abs):
        return None, '脚本不存在: %s' % script_rel

    with BUILDS_LOCK:
        for bid, info in BUILDS.items():
            if info['status'] == 'running':
                return None, '构建 %s 正在进行中，请等待完成' % bid

    build_id = 'build-%d' % int(time.time())
    with BUILDS_LOCK:
        BUILDS[build_id] = {
            'build_id': build_id, 'status': 'running', 'step': step,
            'script': script_rel, 'stage': '准备中', 'progress': 0,
            'output': '', 'exit_code': None,
            'started': time.strftime('%Y-%m-%d %H:%M:%S'), 'finished': '',
        }

    def _work():
        env = os.environ.copy()
        # build-common 默认走 PRUNE_BEFORE_INSTALL=1（白名单已补全类型检查包，
        # install 前裁剪保留它们，tsc 能过；同时 target 更小，SPK < 600MB）
        cmd = ['bash', script_abs]
        try:
            p = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace', cwd=WS_ROOT, env=env)
            out_lines = []
            for line in p.stdout:
                out_lines.append(line.rstrip('\n'))
                with BUILDS_LOCK:
                    b = BUILDS[build_id]
                    b['output'] = '\n'.join(out_lines[-BUILD_LOG_LINES:])
                    for kw, pct in _BUILD_STAGES:
                        if kw in line:
                            b['stage'] = kw
                            b['progress'] = pct
                            break
            p.wait()
            with BUILDS_LOCK:
                b = BUILDS[build_id]
                b['output'] = '\n'.join(out_lines[-BUILD_LOG_LINES:])
                b['exit_code'] = p.returncode
                b['status'] = 'done' if p.returncode == 0 else 'error'
                b['progress'] = 100 if p.returncode == 0 else b['progress']
                b['stage'] = '完成' if p.returncode == 0 else '失败'
                b['finished'] = time.strftime('%Y-%m-%d %H:%M:%S')
            log('BUILD done build_id=%s step=%s exit=%d' % (build_id, step, p.returncode))
        except Exception as e:
            with BUILDS_LOCK:
                b = BUILDS[build_id]
                b['output'] = '执行失败: %s' % e
                b['status'] = 'error'
                b['exit_code'] = 1
                b['finished'] = time.strftime('%Y-%m-%d %H:%M:%S')
                b['stage'] = '异常'
            log('BUILD error build_id=%s: %s' % (build_id, e))

    threading.Thread(target=_work, daemon=True).start()
    log('BUILD start build_id=%s step=%s' % (build_id, step))
    return build_id, ''

# 系统判别特征（实测固化：群晖 / 飞牛各两条以上，任一命中即判）
DSM_FEATURES = ['/etc.defaults/VERSION', '/usr/syno/bin/synopkg']
FNOS_FEATURES = ['/usr/trim', '/usr/local/bin/appcenter-cli', '/usr/local/bin/fnpack']


def read_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def write_config(cfg):
    with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return cfg


def list_packages():
    """扫描工作区候选包：SPK（build/staging、release）与 FPK（release、build/staging）。
    release/ 下按 tag 分目录存放（release/<tag>/*.spk|fpk，sync-github-release.sh 落位），
    故对每个扫描根递归遍历子目录，避免漏掉 release/<tag>/ 里的包。"""
    pkgs = {'spk': [], 'fpk': []}
    roots = [os.path.join(WS_ROOT, 'build', 'staging'), os.path.join(WS_ROOT, 'release')]
    seen = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # 跳过回收站/临时目录（.trash* 等），避免把可恢复的旧包当候选
            dirnames[:] = [d for d in dirnames if not d.startswith('.')]
            for fn in sorted(filenames, reverse=True):
                path = os.path.join(dirpath, fn)
                if not os.path.isfile(path):
                    continue
                low = fn.lower()
                kind = None
                if low.endswith('.spk'):
                    kind = 'spk'
                elif low.endswith('.fpk'):
                    kind = 'fpk'
                if not kind:
                    continue
                if path in seen:
                    continue
                seen.add(path)
                size = os.path.getsize(path)
                # 目录相对工作区显示（如 release/dsh-v0.1.5-rc.2/xxx.fpk），便于区分来源
                rel = os.path.relpath(path, WS_ROOT)
                pkgs[kind].append({
                    'path': path, 'name': fn, 'kind': kind,
                    'rel': rel,
                    'size': '%.1f MB' % (size / 1048576.0),
                    'full': size > 200 * 1048576,
                })
    return pkgs


def detect_system(host, port, username, password, timeout=20):
    """SSH 探测远端系统类型。返回 (system, features)。system ∈ dsm|fnos|unknown|error。"""
    if not (host and username and password):
        return 'error', []
    checks = ' ; '.join('test -e %s && echo YES:%s || echo NO:%s' % (p, p, p) for p in DSM_FEATURES + FNOS_FEATURES)
    cmd = [
        SSHPASS, '-p', password, 'ssh',
        '-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no',
        '-o', 'ConnectTimeout=%d' % timeout, '-o', 'StrictHostKeyChecking=no',
        '-p', str(port), '%s@%s' % (username, host),
        'echo __DSH_DETECT_START__; %s' % checks,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
        out = p.stdout or ''
        features = []
        for m in re.finditer(r'YES:(\S+)', out):
            features.append(m.group(1))
        dsm_hits = [f for f in features if f in DSM_FEATURES]
        fnos_hits = [f for f in features if f in FNOS_FEATURES]
        if dsm_hits:
            system = 'dsm'
        elif fnos_hits:
            system = 'fnos'
        else:
            system = 'unknown'
        return system, features
    except subprocess.TimeoutExpired:
        return 'error', ['SSH 超时']
    except FileNotFoundError:
        return 'error', ['本机缺少 sshpass']
    except Exception as e:
        return 'error', ['%s: %s' % (type(e).__name__, e)]


def run_script(cmd, spk='', system='', note=''):
    """后台执行 install-remote-spk.sh <cmd> [spk] [system]。返回 run_id。
    参数位约定（见 install-remote-spk.sh 解析）:
      install     → bash SCRIPT install <spk> [host] [user] [app] [system]   system=$6
      uninstall/check → bash SCRIPT <cmd> [host] [user] [app] [system]       system=$5
    host/user/app 传空由脚本 ${N:-$(read_cfg)} 兜底；system 传空由脚本推断链兜底。
    note 为用户在网页填写的备注，随安装历史记录（不做任何远程传递，仅本地落盘）。
    """
    run_id = '%d-%d' % (int(time.time() * 1000), threading.get_ident())
    with RUNS_LOCK:
        RUNS[run_id] = {'status': 'running', 'output': '', 'exit_code': None,
                        'started': time.strftime('%H:%M:%S'), 'finished': '',
                        'note': note}

    def _work():
        # repair = 清残留 + 重装（先调 clean-dsm-residue.sh，再 install）
        if cmd == 'repair':
            # 远程真清理：host/user 从已保存配置读（clean-dsm-residue.sh 支持 [主机] [SSH用户]）
            cfg = read_config() or {}
            r_host = cfg.get('host') or cfg.get('ip') or ''
            r_user = cfg.get('user') or cfg.get('username') or cfg.get('account') or ''
            argv_clean = ['bash', os.path.join(BASE_DIR, 'clean-dsm-residue.sh'),
                          'DeepSeekHarness-NAS', r_host, r_user]
            try:
                p0 = subprocess.run(argv_clean, capture_output=True, text=True, timeout=180)
                with RUNS_LOCK:
                    RUNS[run_id]['output'] = '── 清残留 ──\n' + (p0.stdout or '') + (p0.stderr or '') + '\n── 重装 ──\n'
            except Exception as e:
                with RUNS_LOCK:
                    RUNS[run_id]['output'] = '清残留失败: %s\n── 重装 ──\n' % e
            # 继续走 install 流程
            actual_cmd = 'install'
        else:
            actual_cmd = cmd
        argv = ['bash', SCRIPT, actual_cmd]
        if actual_cmd == 'install':
            argv += [spk, '', '', '']
            if system:
                argv.append(system)
        else:
            argv += ['', '', '']
            if system:
                argv.append(system)
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, errors='replace')
            out_lines = []
            for line in p.stdout:
                out_lines.append(line)
                with RUNS_LOCK:
                    RUNS[run_id]['output'] = ''.join(out_lines[-80:])  # 只留尾部
            p.wait()
            with RUNS_LOCK:
                RUNS[run_id]['output'] = ''.join(out_lines)
                RUNS[run_id]['exit_code'] = p.returncode
                RUNS[run_id]['status'] = 'done' if p.returncode == 0 else 'error'
                RUNS[run_id]['finished'] = time.strftime('%H:%M:%S')
                log('DONE run_id=%s cmd=%s exit=%d' % (run_id, cmd, p.returncode))
            # 安装历史落盘（成败都记；repair 已折算为 install，记录用实际执行的命令）
            record_task(actual_cmd, spk, system or '', p.returncode,
                        'success' if p.returncode == 0 else 'failed', run_id,
                        note or '')
        except Exception as e:
            with RUNS_LOCK:
                RUNS[run_id]['output'] = '执行失败: %s' % e
                RUNS[run_id]['status'] = 'error'
                RUNS[run_id]['exit_code'] = 1
                RUNS[run_id]['finished'] = time.strftime('%H:%M:%S')
            record_task(actual_cmd, spk, system or '', 1, 'failed', run_id,
                        note or '')

    threading.Thread(target=_work, daemon=True).start()
    return run_id


class Handler(BaseHTTPRequestHandler):
    server_version = 'DSHInstallServer/2.0'

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, path):
        if os.path.exists(path):
            with open(path, 'rb') as f:
                body = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return True
        return False

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0) or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode('utf-8'))
        except Exception:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ('/', '/install.html', '/install-fpk.html'):
            if self._html(HTML_FILE if path in ('/', '/install.html') else HTML_FILE_LEGACY):
                return
            if self._html(HTML_FILE_LEGACY):
                return
            self._json(404, {'success': False, 'error': '前端页面缺失（install.html / install-fpk.html）'})
        elif path == '/api/config':
            self._json(200, {'success': True, 'config': read_config()})
        elif path == '/api/packages':
            self._json(200, {'success': True, **list_packages()})
        elif path == '/api/log':
            lines = int(parse_qs(parsed.query).get('lines', ['100'])[0])
            try:
                with open(LOG_FILE, 'r', encoding='utf-8') as f:
                    all_lines = f.readlines()
                tail = all_lines[-lines:] if len(all_lines) > lines else all_lines
                self._json(200, {'success': True, 'log': ''.join(tail), 'total': len(all_lines)})
            except FileNotFoundError:
                self._json(200, {'success': True, 'log': '', 'total': 0})
            except Exception as e:
                self._json(500, {'success': False, 'error': str(e)})
        elif path == '/api/run-status':
            run_id = parse_qs(parsed.query).get('run_id', [''])[0]
            with RUNS_LOCK:
                info = dict(RUNS.get(run_id, {}))
            if not info:
                self._json(404, {'success': False, 'error': f'未找到任务 {run_id}'})
            else:
                self._json(200, {'success': True, **info})
        elif path == '/api/tasks':
            # 安装历史（install-tasks.jsonl，最新在前；纯标准库读尾部）
            limit = min(int(parse_qs(parsed.query).get('limit', ['50'])[0]), 500)
            tasks = []
            try:
                with open(TASKS_FILE, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                for ln in lines[-limit:]:
                    ln = ln.strip()
                    if not ln:
                        continue
                    try:
                        tasks.append(json.loads(ln))
                    except Exception:
                        continue
                tasks.reverse()
                self._json(200, {'success': True, 'tasks': tasks, 'total': len(lines)})
            except FileNotFoundError:
                self._json(200, {'success': True, 'tasks': [], 'total': 0})
            except Exception as e:
                self._json(500, {'success': False, 'error': str(e)})
        elif path == '/api/build-status':
            build_id = parse_qs(parsed.query).get('build_id', [''])[0]
            with BUILDS_LOCK:
                info = dict(BUILDS.get(build_id, {}))
            if not info:
                self._json(404, {'success': False, 'error': '未找到构建任务 %s' % build_id})
            else:
                self._json(200, {'success': True, **info})
        elif path == '/api/builds':
            with BUILDS_LOCK:
                builds = sorted(BUILDS.values(), key=lambda b: b.get('started', ''), reverse=True)
            self._json(200, {'success': True, 'builds': list(builds)})
        else:
            self._json(404, {'success': False, 'error': f'未知路径: {path}'})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._read_body()
        if path == '/api/save':
            if not body:
                self._json(400, {'success': False, 'error': '空请求体'})
                return
            write_config(body)
            safe = dict(body)
            if safe.get('password'):
                safe['password'] = '******'
            log('SAVE config host=%s user=%s' % (safe.get('host',''), safe.get('username','')))
            self._json(200, {'success': True, 'config': safe,
                             'file': CONFIG_FILE})
        elif path == '/api/detect':
            host = str(body.get('host', '')).strip()
            port = int(body.get('port') or 22)
            username = str(body.get('username', '')).strip()
            password = str(body.get('password', '') or read_config().get('password', '')).strip()
            if not host or not username:
                self._json(400, {'success': False, 'error': '缺少 host/username'})
                return
            log('DETECT host=%s@%s:%s' % (username, host, port))
            system, features = detect_system(host, port, username, password)
            log('DETECT result=%s features=%s' % (system, features))
            self._json(200, {
                'success': system != 'error',
                'system': system,
                'package_type': 'spk' if system == 'dsm' else ('fpk' if system == 'fnos' else ''),
                'features': features,
                'hint': {'dsm': '✅ 群晖 DSM → 装 SPK 套件',
                         'fnos': '✅ 飞牛 fnOS → 装 FPK 应用',
                         'unknown': '⚠️ 未识别系统（两者特征都未命中）',
                         'error': '❌ 探测失败'}.get(system, ''),
            })
        elif path == '/api/run':
            cmd = str(body.get('cmd', '')).strip()
            spk = str(body.get('spk', '')).strip()
            system = str(body.get('system', '')).strip()
            note = str(body.get('note', '')).strip()[:200]   # 备注上限 200 字，仅本地历史落盘
            if cmd not in ('install', 'uninstall', 'check', 'repair'):
                self._json(400, {'success': False, 'error': 'cmd 必须是 install|uninstall|check|repair'})
                return
            run_id = run_script(cmd, spk, system, note)
            log('RUN cmd=%s spk=%s system=%s note=%s -> run_id=%s' % (cmd, os.path.basename(spk) if spk else '', system, note, run_id))
            self._json(200, {'success': True, 'run_id': run_id, 'cmd': cmd})
        elif path == '/api/build':
            step = str(body.get('step', '')).strip()
            if step not in ('common', 'spk', 'fpk'):
                self._json(400, {'success': False, 'error': 'step 必须是 common|spk|fpk'})
                return
            build_id, err = start_build(step)
            if err:
                self._json(409, {'success': False, 'error': err})
            else:
                self._json(200, {'success': True, 'build_id': build_id, 'step': step})
        elif path == '/api/publish':
            package = str(body.get('package', '')).strip()
            if not package:
                self._json(400, {'success': False, 'error': '缺少 package 参数'})
                return
            # 从包名提取版本号，构造 tag
            version = extract_version(package)
            if not version:
                self._json(400, {'success': False, 'error': '无法从包名提取版本号: %s' % package})
                return
            tag = 'v%s' % version
            # 查找文件
            file_path = _find_package_file(package)
            if not file_path:
                self._json(404, {'success': False, 'error': '未找到包文件: %s' % package})
                return
            log('PUBLISH package=%s tag=%s file=%s' % (package, tag, file_path))
            ok, msg = publish_package_to_github(file_path, tag)
            log('PUBLISH result: ok=%s msg=%s' % (ok, msg))
            if ok:
                self._json(200, {'success': True, 'message': msg, 'tag': tag})
            else:
                self._json(500, {'success': False, 'error': msg})
        else:
            self._json(404, {'success': False, 'error': f'未知路径: {path}'})

    def log_message(self, fmt, *args):
        sys.stderr.write('[%s] %s\n' % (self.log_date_time_string(), fmt % args))


def main():
    log('=== install-server.py 启动 port=%d ===' % PORT)
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'DSH 安装工具服务端已启动: http://0.0.0.0:{PORT}/install.html')
    print(f'配置落盘: {CONFIG_FILE}')
    print(f'脚本调用: {SCRIPT}')
    print(f'日志文件: {LOG_FILE}')
    server.serve_forever()


if __name__ == '__main__':
    main()