#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DeepSeekHarness-NAS 安装工具服务端（网页直调远程脚本版）
- GET  /                      前端页面（install.html / install-fpk.html）
- GET  /api/config            读取已保存的配置（web-install/install-config.json）
- POST /api/save              保存配置（web-install/install-config.json）
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
CONFIG_FILE = os.path.join(BASE_DIR, 'install-config.json')   # 2026-09-15 归位 web-install/（与 install-remote-spk.sh 同源！）
TASKS_FILE = os.path.join(BASE_DIR, 'install-tasks.jsonl')
LOG_FILE = os.path.join(BASE_DIR, 'install-server.log')
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


_CHUNK_1MIB = 1024 * 1024   # 流式读包的分块大小（1 MiB）：既避免整载入内存，也不至于调用过碎


def file_md5(path):
    """本地计算包文件 MD5（历史记录用；大包流式读，不整载入内存）"""
    import hashlib
    h = hashlib.md5()
    try:
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(_CHUNK_1MIB), b''):
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


# ── Release 文案：唯一出处 build/release-note.sh（禁止在本文件另写一套）──────────
#   与 CI（.github/workflows/build.yml）调用同一脚本渲染标题与正文（含官方更新日志），
#   保证「改一处、三条发布路径一致」：CI 源码链 / CI npm 链 / 本 web 端。
def _release_note(kind, tag, mode=None, fname=None):
    """取 release-note.sh 渲染的文案；任何失败返回 ''（由调用方回退，不阻断发布）。"""
    script = os.path.join(WS_ROOT, 'build', 'release-note.sh')
    if not os.path.isfile(script):
        log('RELEASE note script missing: %s' % script)
        return ''
    if mode is None:
        mode = 'npm' if tag.endswith('-npm') else 'main'
    env = dict(os.environ, MODE=mode, RELEASE_TAG=tag)
    # 状态徽标：web 端发布没有 CI 结果可读，按"本次发布的产物"如实置位，
    #   否则正文会渲染成「缺失（CI 失败）」，与正在发布的事实矛盾。
    _low = (fname or '').lower()
    if _low.endswith('.spk'):
        env.update(SPK_STATUS='success', SPK_DESC='web 端本地构建,源码链路')
    elif _low.endswith('.fpk'):
        if mode == 'npm':
            env.update(FPK_NPM_STATUS='success', FPK_NPM_DESC='web 端本地构建,npm 链路')
        else:
            env.update(FPK_SOURCE_STATUS='success', FPK_SOURCE_DESC='web 端本地构建,源码链路')
    try:
        r = subprocess.run(['bash', script, kind, tag], env=env, cwd=WS_ROOT,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if r.returncode != 0:
            log('RELEASE note %s failed rc=%d: %s' % (kind, r.returncode,
                r.stderr.decode('utf-8', 'replace')[:200]))
            return ''
        return r.stdout.decode('utf-8', 'replace').strip()
    except Exception as e:
        log('RELEASE note %s error: %s' % (kind, e))
        return ''


def _copy_to_release_dir(file_path, tag):
    """把产物复制到 release/<tag>/（已在该目录则跳过）。返回 (ok, dst, message)。"""
    fname = os.path.basename(file_path)
    release_dir = os.path.join(WS_ROOT, 'release', tag)
    os.makedirs(release_dir, exist_ok=True)
    dst = os.path.join(release_dir, fname)
    if os.path.abspath(file_path) == os.path.abspath(dst):
        return True, dst, ''
    import shutil
    try:
        shutil.copy2(file_path, dst)
        log('RELEASE copy %s -> %s' % (fname, release_dir))
        return True, dst, ''
    except Exception as e:
        log('RELEASE copy failed: %s' % e)
        return False, dst, '复制产物失败: %s' % e


def _get_or_create_release(tag, fname, token):
    """取同名 Release；不存在（404）则按官方 tag 创建。返回 (ok, rel, message)。"""
    status, rel = _github_api('GET', '/repos/%s/releases/tags/%s' % (GITHUB_REPO, tag), token)
    if status == 404:
        status, rel = _github_api('POST', '/repos/%s/releases' % GITHUB_REPO, token, {
            'tag_name': tag,
            'name': _release_note('title', tag, fname=fname) or ('Release %s' % tag),
            'body': _release_note('body', tag, fname=fname) or ('Version: %s' % tag.lstrip('v')),
            'draft': False,
            'prerelease': '-' in tag,
        })
        if status not in (200, 201):
            return False, rel, '创建 Release 失败: %s' % rel
        log('RELEASE created %s (id=%s)' % (tag, rel.get('id')))
    elif status == 200:
        log('RELEASE found %s (id=%s)' % (tag, rel.get('id')))
    else:
        return False, rel, '查询 Release 失败: %s' % rel
    if not rel.get('upload_url', ''):
        return False, rel, 'Release 缺少 upload_url'
    return True, rel, ''


def _replace_asset(rel, token, dst, fname, tag):
    """先删同名旧资产（GitHub 不允许重名），再上传。返回 (ok, message)。

    先删后传是刻意的：同名资产不删会让上传拿到 422，而 Release 是"滚动刷新"语义，
    每次发版都该是同一批文件名。
    """
    for a in rel.get('assets', []):
        if a.get('name') == fname:
            log('RELEASE asset already exists: %s (id=%s), deleting old' % (fname, a.get('id')))
            _github_api('DELETE', '/repos/%s/releases/assets/%s' % (GITHUB_REPO, a['id']), token)
    fsize = os.path.getsize(dst)
    log('RELEASE upload %s (%.1f MB)' % (fname, fsize / _CHUNK_1MIB))
    status, resp = _upload_release_asset(rel.get('upload_url', ''), token, dst, fname)
    if status in (200, 201):
        log('RELEASE upload OK: %s' % fname)
        return True, '✅ 已发布 %s 到 %s' % (fname, tag)
    log('RELEASE upload FAILED: %s -> %s' % (fname, resp))
    return False, '上传失败: %s' % resp


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
    ok, dst, msg = _copy_to_release_dir(file_path, tag)
    if not ok:
        return False, msg

    ok, rel, msg = _get_or_create_release(tag, fname, token)
    if not ok:
        return False, msg
    return _replace_asset(rel, token, dst, fname, tag)


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
    'spk':    'build/SPK/pack-spk.sh',
    'fpk':    'build/FPK/pack-fpk.sh',
}


def _validate_build_step(step):
    """校验 step 并解析脚本路径。返回 (script_rel, script_abs, error)。"""
    script_rel = _BUILD_SCRIPTS.get(step)
    if not script_rel:
        return None, None, 'step 必须是 common|spk|fpk'
    script_abs = os.path.join(WS_ROOT, script_rel)
    if not os.path.isfile(script_abs):
        return script_rel, script_abs, '脚本不存在: %s' % script_rel
    return script_rel, script_abs, ''


def _ensure_no_running_build():
    """同一时刻只允许一个构建（构建吃满磁盘/CPU，并发会把两者都拖死）。返回错误信息或空串。"""
    with BUILDS_LOCK:
        for bid, info in BUILDS.items():
            if info['status'] == 'running':
                return '构建 %s 正在进行中，请等待完成' % bid
    return ''


# ── 构建参数（网页「构建参数」面板）→ 打包脚本环境变量 ────────────────────────
# 三个构建步各认一套变量（2026-10-05 逐处核对，勿凭印象；FPKCFG_* / SPKCFG_* 里含 CFG_* 子串，
# 用 grep 子串判断会误判成"两边通用"）：
#   common（build-common.sh）→ APP_NAME
#   spk   （pack-spk.sh）    → SPKCFG_*   （2026-10-05 起与 FPK 统一命名）
#   fpk   （pack-fpk.sh）    → FPKCFG_*
# 故同一个网页字段同时注入多套别名：每步各取所需，不必按步分支（更稳，且三步混跑也一致）。
# 两个打包脚本都已加"环境里已指定则不覆盖"保护，故这里的值不会被 YAML 静默冲掉。
# ⚠ 只列【确实被脚本读取】的变量：例如"版本号"目前没有覆盖点（PKG_VER 取自源码
#   package.json，build-common.sh:278），故这里**不**发明 CFG_BRAND_VERSION 之类无人读的变量。
BUILD_PARAM_ALIASES = {
    'appname':        ('APP_NAME', 'SPKCFG_APPNAME', 'FPKCFG_APPNAME'),
    'brand_name':     ('SPKCFG_BRAND_NAME', 'FPKCFG_BRAND_NAME'),
    'display_name':   ('SPKCFG_DISPLAY_NAME', 'FPKCFG_DISPLAY_NAME'),
    'title':          ('SPKCFG_TITLE', 'FPKCFG_TITLE'),
    'desc':           ('SPKCFG_DESC', 'FPKCFG_DESC'),
    'desc_short':     ('SPKCFG_DESC_SHORT', 'FPKCFG_DESC_SHORT'),
    'maintainer':     ('SPKCFG_MAINTAINER', 'FPKCFG_MAINTAINER'),
    'distributor':    ('SPKCFG_DISTRIBUTOR', 'FPKCFG_DISTRIBUTOR'),
    'proxy_port':     ('SPKCFG_PROXY_PORT', 'FPKCFG_PROXY_PORT'),
    'dsh_port':       ('SPKCFG_DSH_PORT', 'FPKCFG_DSH_PORT'),
    'container_port': ('SPKCFG_CONTAINER_PORT', 'FPKCFG_CONTAINER_PORT'),
}


def _build_param_env(params):
    """把网页填的自定义参数转成子进程环境变量（只影响这一次构建）。

    空值忽略（空 = 不覆盖，回落 build-config.yaml 的权威值）；未知键忽略。
    """
    env = {}
    for k, v in (params or {}).items():
        aliases = BUILD_PARAM_ALIASES.get(k)
        if not aliases:
            continue
        s = str(v).strip()
        if not s:
            continue
        for alias in aliases:
            env[alias] = s
    return env


def _stream_build(build_id, cmd, step, env_extra=None):
    """执行构建、边跑边刷新输出与阶段进度，结束（或异常）后落最终状态。

    env_extra：本次构建的自定义参数（网页「构建参数」面板填的品牌 / 简介 / 端口等）。
    以 CFG_* / FPKCFG_* / APP_NAME 形式注入**子进程环境** —— 打包脚本本就支持这类覆盖
    （build-config.yaml 头部即写明「优先级：命令行参数 > YAML section > YAML defaults」），
    因此自定义**只影响这一次构建**，不修改权威文件 build/build-config.yaml。
    """
    try:
        _env = os.environ.copy()
        if env_extra:
            _env.update(env_extra)
        p = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors='replace', cwd=WS_ROOT, env=_env)
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


def start_build(step='common', params=None):
    """后台执行构建脚本。返回 (build_id, error_msg)。

    params：可选的本次构建自定义参数（品牌 / 简介 / 端口等），经 _build_param_env()
    变成子进程环境变量交给打包脚本；不传则完全按权威配置构建。
    """
    script_rel, script_abs, err = _validate_build_step(step)
    if err:
        return None, err
    err = _ensure_no_running_build()
    if err:
        return None, err

    # 自定义参数 → 环境变量（空值/未知键自动忽略，回落权威配置）
    params_env = _build_param_env(params or {})

    build_id = 'build-%d' % int(time.time())
    with BUILDS_LOCK:
        BUILDS[build_id] = {
            'build_id': build_id, 'status': 'running', 'step': step,
            'script': script_rel, 'stage': '准备中', 'progress': 0,
            'output': '', 'exit_code': None,
            'params': sorted((params or {}).keys()),
            'started': time.strftime('%Y-%m-%d %H:%M:%S'), 'finished': '',
        }

    def _work():
        # 不覆盖 PRUNE_BEFORE_INSTALL：build-common.sh 默认走 1（白名单已补全类型检查包，
        # install 前裁剪保留它们，tsc 能过；同时 target 更小，SPK < 600MB）。
        _stream_build(build_id, ['bash', script_abs], step, env_extra=params_env)

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
                    'size': '%.1f MB' % (size / _CHUNK_1MIB),
                    'full': size > 200 * 1048576,
                })
    return pkgs


def _build_detect_cmd(host, port, username, password, timeout):
    """拼出「一条 SSH 命令里把所有特征路径都 test 一遍」的 argv。

    一次连接就探完 DSM/FNOS 全部特征路径，避免逐个路径重连（探测慢且易触发失败计数）。
    """
    checks = ' ; '.join('test -e %s && echo YES:%s || echo NO:%s' % (p, p, p)
                        for p in DSM_FEATURES + FNOS_FEATURES)
    return [
        SSHPASS, '-p', password, 'ssh',
        '-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no',
        '-o', 'ConnectTimeout=%d' % timeout, '-o', 'StrictHostKeyChecking=no',
        '-p', str(port), '%s@%s' % (username, host),
        'echo __DSH_DETECT_START__; %s' % checks,
    ]


def _classify_system(features):
    """按命中的特征路径判定系统类型：命中 DSM 特征即 dsm，其次 fnos，都没有则 unknown。

    注意顺序：先判 DSM —— 两种系统可能有同名路径，以先命中者为准（与历史行为一致）。
    """
    dsm_hits = [f for f in features if f in DSM_FEATURES]
    if dsm_hits:
        return 'dsm'
    if [f for f in features if f in FNOS_FEATURES]:
        return 'fnos'
    return 'unknown'


def detect_system(host, port, username, password, timeout=20):
    """SSH 探测远端系统类型。返回 (system, features)。system ∈ dsm|fnos|unknown|error。"""
    if not (host and username and password):
        return 'error', []
    cmd = _build_detect_cmd(host, port, username, password, timeout)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
        out = p.stdout or ''
        features = [m.group(1) for m in re.finditer(r'YES:(\S+)', out)]
        return _classify_system(features), features
    except subprocess.TimeoutExpired:
        return 'error', ['SSH 超时']
    except FileNotFoundError:
        return 'error', ['本机缺少 sshpass']
    except Exception as e:
        return 'error', ['%s: %s' % (type(e).__name__, e)]


def _repair_clean_first(run_id):
    """repair 的前置步骤：先远程清残留，再按 install 走。返回实际要执行的子命令。

    host/user 从已保存配置读（clean-dsm-residue.sh 支持 [主机] [SSH用户]）。
    默认 --keep-data：repair 的本意是清**程序残留**再重装，不该动用户数据
    （此前 clean-dsm-residue.sh 无条件删 @appdata/@apphome/@appshare，数据丢失事故即经此路径）。
    清理失败不中断：把失败写进输出后仍继续重装（让用户看到原因，而不是整条任务卡住）。
    """
    cfg = read_config() or {}
    r_host = cfg.get('host') or cfg.get('ip') or ''
    r_user = cfg.get('user') or cfg.get('username') or cfg.get('account') or ''
    argv_clean = ['bash', os.path.join(BASE_DIR, 'clean-dsm-residue.sh'),
                  'DeepSeekHarness-NAS', r_host, r_user, '--keep-data']
    try:
        p0 = subprocess.run(argv_clean, capture_output=True, text=True, timeout=180)
        with RUNS_LOCK:
            RUNS[run_id]['output'] = '── 清残留 ──\n' + (p0.stdout or '') + (p0.stderr or '') + '\n── 重装 ──\n'
    except Exception as e:
        with RUNS_LOCK:
            RUNS[run_id]['output'] = '清残留失败: %s\n── 重装 ──\n' % e
    return 'install'


def _build_argv(actual_cmd, spk, system, keep_data):
    """按 install-remote-spk.sh 的位置约定拼 argv。

    install 走 install <spk> [host] [user] [app] [system]（system 是第 6 位），
    uninstall/check 走 <cmd> [host] [user] [app] [system]（system 是第 5 位），
    host/user/app 一律留空由脚本 ${N:-$(read_cfg)} 兜底。
    uninstall 额外追加 --keep-data/--delete-data：默认保留数据（与套件卸载向导一致）。
    """
    argv = ['bash', SCRIPT, actual_cmd]
    if actual_cmd == 'install':
        argv += [spk, '', '', '']
        if system:
            argv.append(system)
    else:
        argv += ['', '', '']
        if system:
            argv.append(system)
        if actual_cmd == 'uninstall':
            argv.append('--keep-data' if keep_data else '--delete-data')
    return argv


def _stream_and_record(run_id, argv, actual_cmd, spk, system, note):
    """执行子进程、边跑边刷新输出（只留尾部 80 行）、结束后落安装历史。

    成败都记录；repair 已折算为 install，故记录用 actual_cmd。
    """
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
            log('DONE run_id=%s cmd=%s exit=%d' % (run_id, actual_cmd, p.returncode))
        record_task(actual_cmd, spk, system or '', p.returncode,
                    'success' if p.returncode == 0 else 'failed', run_id, note or '')
    except Exception as e:
        with RUNS_LOCK:
            RUNS[run_id]['output'] = '执行失败: %s' % e
            RUNS[run_id]['status'] = 'error'
            RUNS[run_id]['exit_code'] = 1
            RUNS[run_id]['finished'] = time.strftime('%H:%M:%S')
        record_task(actual_cmd, spk, system or '', 1, 'failed', run_id, note or '')


def run_script(cmd, spk='', system='', note='', keep_data=True):
    """后台执行 install-remote-spk.sh <cmd> [spk] [system]。返回 run_id。
    参数位约定（见 install-remote-spk.sh 解析）:
      install     → bash SCRIPT install <spk> [host] [user] [app] [system]   system=$6
      uninstall/check → bash SCRIPT <cmd> [host] [user] [app] [system]       system=$5
      uninstall 另可追加 --keep-data/--delete-data：**默认 --keep-data 保留数据**
        （与套件卸载向导默认一致；keep_data=False 才连数据一起删）
    host/user/app 传空由脚本 ${N:-$(read_cfg)} 兜底；system 传空由脚本推断链兜底。
    note 为用户在网页填写的备注，随安装历史记录（不做任何远程传递，仅本地落盘）。
    """
    run_id = '%d-%d' % (int(time.time() * 1000), threading.get_ident())
    with RUNS_LOCK:
        RUNS[run_id] = {'status': 'running', 'output': '', 'exit_code': None,
                        'started': time.strftime('%H:%M:%S'), 'finished': '',
                        'note': note}

    def _work():
        # repair = 清残留 + 重装；其余命令原样执行
        actual_cmd = _repair_clean_first(run_id) if cmd == 'repair' else cmd
        argv = _build_argv(actual_cmd, spk, system, keep_data)
        _stream_and_record(run_id, argv, actual_cmd, spk, system, note)

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

    def _api_config(self):
        return 200, {'success': True, 'config': read_config()}

    def _api_packages(self):
        return 200, {'success': True, **list_packages()}

    def _api_log(self, query):
        lines = int(parse_qs(query).get('lines', ['100'])[0])
        try:
            with open(LOG_FILE, 'r', encoding='utf-8') as f:
                all_lines = f.readlines()
            tail = all_lines[-lines:] if len(all_lines) > lines else all_lines
            return 200, {'success': True, 'log': ''.join(tail), 'total': len(all_lines)}
        except FileNotFoundError:
            return 200, {'success': True, 'log': '', 'total': 0}
        except Exception as e:
            return 500, {'success': False, 'error': str(e)}

    def _api_run_status(self, query):
        run_id = parse_qs(query).get('run_id', [''])[0]
        with RUNS_LOCK:
            info = dict(RUNS.get(run_id, {}))
        if not info:
            return 404, {'success': False, 'error': f'未找到任务 {run_id}'}
        return 200, {'success': True, **info}

    def _api_tasks(self, query):
        # 安装历史（install-tasks.jsonl，最新在前；纯标准库读尾部）
        limit = min(int(parse_qs(query).get('limit', ['50'])[0]), 500)
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
            return 200, {'success': True, 'tasks': tasks, 'total': len(lines)}
        except FileNotFoundError:
            return 200, {'success': True, 'tasks': [], 'total': 0}
        except Exception as e:
            return 500, {'success': False, 'error': str(e)}

    def _api_build_status(self, query):
        build_id = parse_qs(query).get('build_id', [''])[0]
        with BUILDS_LOCK:
            info = dict(BUILDS.get(build_id, {}))
        if not info:
            return 404, {'success': False, 'error': '未找到构建任务 %s' % build_id}
        return 200, {'success': True, **info}

    def _api_builds(self):
        with BUILDS_LOCK:
            builds = sorted(BUILDS.values(), key=lambda b: b.get('started', ''), reverse=True)
        return 200, {'success': True, 'builds': list(builds)}

    def do_GET(self):
        """GET 路由：静态页面直接写字节（必须留在本方法），API 走下面的 (状态码, 载荷) 小函数。

        API 小函数只返回数据、不碰 socket，因此可脱离服务器单测（见本次重构的验证方式）。
        """
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ('/', '/install.html', '/install-fpk.html'):
            if self._html(HTML_FILE if path in ('/', '/install.html') else HTML_FILE_LEGACY):
                return
            if self._html(HTML_FILE_LEGACY):
                return
            self._json(404, {'success': False, 'error': '前端页面缺失（install.html / install-fpk.html）'})
            return
        routes = {
            '/api/config': lambda: self._api_config(),
            '/api/packages': lambda: self._api_packages(),
            '/api/log': lambda: self._api_log(parsed.query),
            '/api/run-status': lambda: self._api_run_status(parsed.query),
            '/api/tasks': lambda: self._api_tasks(parsed.query),
            '/api/build-status': lambda: self._api_build_status(parsed.query),
            '/api/builds': lambda: self._api_builds(),
        }
        handler = routes.get(path)
        if handler is None:
            self._json(404, {'success': False, 'error': f'未知路径: {path}'})
            return
        status, payload = handler()
        self._json(status, payload)

    def _api_save(self, body):
        if not body:
            return 400, {'success': False, 'error': '空请求体'}
        write_config(body)
        safe = dict(body)
        if safe.get('password'):
            safe['password'] = '******'
        log('SAVE config host=%s user=%s' % (safe.get('host', ''), safe.get('username', '')))
        return 200, {'success': True, 'config': safe, 'file': CONFIG_FILE}

    def _api_detect(self, body):
        host = str(body.get('host', '')).strip()
        port = int(body.get('port') or 22)
        username = str(body.get('username', '')).strip()
        password = str(body.get('password', '') or read_config().get('password', '')).strip()
        if not host or not username:
            return 400, {'success': False, 'error': '缺少 host/username'}
        log('DETECT host=%s@%s:%s' % (username, host, port))
        system, features = detect_system(host, port, username, password)
        log('DETECT result=%s features=%s' % (system, features))
        return 200, {
            'success': system != 'error',
            'system': system,
            # package_type 供前端决定推 SPK 还是 FPK 安装包，勿删
            'package_type': 'spk' if system == 'dsm' else ('fpk' if system == 'fnos' else ''),
            'features': features,
            'hint': {'dsm': '✅ 群晖 DSM → 装 SPK 套件',
                     'fnos': '✅ 飞牛 fnOS → 装 FPK 应用',
                     'unknown': '⚠️ 未识别系统（两者特征都未命中）',
                     'error': '❌ 探测失败'}.get(system, ''),
        }

    def _api_run(self, body):
        cmd = str(body.get('cmd', '')).strip()
        spk = str(body.get('spk', '')).strip()
        system = str(body.get('system', '')).strip()
        note = str(body.get('note', '')).strip()[:200]   # 备注上限 200 字，仅本地历史落盘
        if cmd not in ('install', 'uninstall', 'check', 'repair'):
            return 400, {'success': False, 'error': 'cmd 必须是 install|uninstall|check|repair'}
        _kd = body.get('keep_data', True)
        keep_data = False if str(_kd).lower() in ('0', 'false', 'no') else True
        run_id = run_script(cmd, spk, system, note, keep_data)
        log('RUN cmd=%s spk=%s system=%s note=%s -> run_id=%s'
            % (cmd, os.path.basename(spk) if spk else '', system, note, run_id))
        return 200, {'success': True, 'run_id': run_id, 'cmd': cmd}

    def _api_build(self, body):
        step = str(body.get('step', '')).strip()
        if step not in ('common', 'spk', 'fpk'):
            return 400, {'success': False, 'error': 'step 必须是 common|spk|fpk'}
        # 网页「构建参数」面板的自定义项（可选）：品牌 / 简介 / 端口等
        params = body.get('params') or {}
        if not isinstance(params, dict):
            return 400, {'success': False, 'error': 'params 必须是对象'}
        build_id, err = start_build(step, params)
        if err:
            return 409, {'success': False, 'error': err}
        return 200, {'success': True, 'build_id': build_id, 'step': step,
                     'params': sorted(params.keys())}

    def _api_publish(self, body):
        package = str(body.get('package', '')).strip()
        if not package:
            return 400, {'success': False, 'error': '缺少 package 参数'}
        # 从包名提取版本号，构造 tag
        version = extract_version(package)
        if not version:
            return 400, {'success': False, 'error': '无法从包名提取版本号: %s' % package}
        tag = 'v%s' % version
        file_path = _find_package_file(package)
        if not file_path:
            return 404, {'success': False, 'error': '未找到包文件: %s' % package}
        log('PUBLISH package=%s tag=%s file=%s' % (package, tag, file_path))
        ok, msg = publish_package_to_github(file_path, tag)
        log('PUBLISH result: ok=%s msg=%s' % (ok, msg))
        if ok:
            return 200, {'success': True, 'message': msg, 'tag': tag}
        return 500, {'success': False, 'error': msg}

    def do_POST(self):
        """POST 路由：每条路由一个返回 (状态码, 载荷) 的小函数。

        与 do_GET 同样的小函数约定 —— 校验分支（400/404）不触发副作用，可脱离服务器单测；
        有副作用的路径（写配置/起进程/发布）行为逐字保持。
        """
        path = urlparse(self.path).path
        body = self._read_body()
        routes = {
            '/api/save': lambda: self._api_save(body),
            '/api/detect': lambda: self._api_detect(body),
            '/api/run': lambda: self._api_run(body),
            '/api/build': lambda: self._api_build(body),
            '/api/publish': lambda: self._api_publish(body),
        }
        handler = routes.get(path)
        if handler is None:
            self._json(404, {'success': False, 'error': f'未知路径: {path}'})
            return
        status, payload = handler()
        self._json(status, payload)

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