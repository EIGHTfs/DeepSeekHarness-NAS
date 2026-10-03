#!/bin/bash
# ============================================================
#  migrate-session.sh —— DSH 会话跨版本迁移工具
#
#  背景：DSH 会话格式为预发布格式，磁盘版本随 harness 版本演进
#  （0.1.2 写 v0，0.1.5+ 为 v3）。官方不提供迁移命令，但持久化层在
#  「打开会话」时会自动把低版本 generation 沿迁移边串行还原
#  （v0→v1→v2→v3，见 packages/session/session-format-*-to-*）。
#  本脚本负责：把源会话安全投放为目标 home 中一个「可被自动迁移」的
#  generation，并把两处已知会导致 DSH 激活失败的格式陷阱挡在前面。
#
#  两个必须遵守的格式契约（踩过的坑，勿删校验）：
#   1. sessions/ 根下只允许 --<cwd编码>-- 形式的目录；任何裸目录会触发
#      "unsupported flat-file layout"，导致 workspaceRegistry 激活失败，
#      表现为「工作区列表为空 + directoryPickerController unavailable」。
#      → 备份一律放 home 之外的 <home>/../session-backups/。
#   2. session.jsonl.zstd 的第一个 zstd frame 必须「正好是一行 header」
#      （v0 布局为每行独立成帧；典型文件有数万个 frame）。用 zstd 整体
#      重压缩会把所有帧合并为一帧，触发
#      "corrupt Zstandard session log: first frame is not exactly one header line"。
#      → 改 header 必须只重建首帧，其余字节原样拼接。
#
#  用法:
#    ./migrate-session.sh --list
#        列出目标 home 中的会话及其磁盘版本/generation。
#    ./migrate-session.sh --check <session.zstd 路径>
#        只做格式体检（首帧契约、帧数、行数、header 字段），不落盘。
#    ./migrate-session.sh --cwd <新cwd> --in <源文件> --id <session-id> [--home <DSH_HOME>]
#        投放：校验 → 重写首帧 cwd → 落到 sessions/<编码目录>/<id>/ → 登记工作区。
#    ./migrate-session.sh --rollback <备份名>
#        从 <home>/../session-backups/ 恢复一次投放前的备份。
#
#  设计约束:
#    * 幂等：重复投放同名会话会先备份既有 generation 再覆盖。
#    * 不启动/不停止 DSH：迁移应在 DSH 停止时执行，由使用者自行控制。
#    * 只改首帧，不动其余字节 → 保留源文件的全部历史与引用关系。
# ============================================================
set -u
set -o pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

# ---------- 定位 DSH_HOME ----------
# 依次尝试：显式参数 > 环境变量 > 相对本脚本推断 > 常见套件路径
detect_home() {
  [ -n "${DSH_HOME:-}" ] && { echo "$DSH_HOME"; return 0; }
  local cand
  for cand in \
    "/volume1/@appdata/DeepSeekHarness-NAS/0.1.6-alpha.1/.dsh" \
    "/volume1/@appdata/DeepSeekHarness-NAS/current/.dsh" \
    "$HOME/.dsh"
  do
    [ -d "$cand" ] && { echo "$cand"; return 0; }
  done
  # 兜底：扫 @appdata 下的 .dsh
  cand="$(ls -d /volume1/@appdata/DeepSeekHarness-NAS/*/.dsh 2>/dev/null | head -1)"
  [ -n "$cand" ] && { echo "$cand"; return 0; }
  return 1
}

# ---------- 找 node（与仓库其它脚本一致，不硬编码） ----------
# 找 node：覆盖 DSH 套件自带 node（群晖路径与仓库相对路径）、系统路径、PATH 兜底
find_node() {
  local d
  for d in \
    "$SCRIPT_DIR/../target/bin/node" \
    "$SCRIPT_DIR/../bin/node" \
    "/var/packages/DeepSeekHarness-NAS/target/bin/node" \
    "/usr/local/bin/node" \
    "/usr/bin/node"
  do
    [ -x "$d" ] && { echo "$d"; return 0; }
  done
  # 兜底：扫套件目录下的 node
  d="$(ls /var/packages/DeepSeekHarness-NAS/*/target/bin/node 2>/dev/null | head -1)"
  [ -n "$d" ] && [ -x "$d" ] && { echo "$d"; return 0; }
  command -v node 2>/dev/null
}

NODE_BIN="$(find_node)" || { echo "[migrate] 未找到 node" >&2; exit 1; }

# ---------- cwd → 会话目录名编码 ----------
# 规则（实测自 DSH 生成的目录名）：
#   '/' → '-' ; 空格 → '~0020' ; '@' → '~0040'
#   其余可打印 ASCII 原样 ; 非 ASCII 按 Unicode 码点 → '~XXXX'(大写hex)
# 例：/volume1/@appdata/.../0.1.6-alpha.1/工作区
#     → --volume1-~0040appdata-...-0.1.6-alpha.1-~5DE5~4F5C~533A--
encode_cwd() {
  "$NODE_BIN" -e '
    const s = process.argv[1];
    let out = "";
    for (let i = 0; i < s.length; i++) {
      const ch = s[i], cp = s.codePointAt(i);
      if (ch === "/") {
        // 路径开头的斜杠由 "--" 前缀代表，不再重复输出
        if (i === 0) continue;
        out += "-";
      }
      else if (ch === " ") out += "~0020";
      // 安全字符原样保留
      else if (/[A-Za-z0-9._~-]/.test(ch)) out += ch;
      // 其余（@ # 中文 …）按 Unicode 码点转义为 ~XXXX
      else out += "~" + cp.toString(16).toUpperCase().padStart(4, "0");
    }
    process.stdout.write("--" + out + "--");
  ' "$1"
}

# ---------- 明文 jsonl → zstd（保持 v0 帧契约） ----------
# DSH 的 compression 配置决定物理编码：zstd 时只认 .jsonl.zstd。
# 会话导出包里的 session.jsonl 是明文，投放前需转码；转码必须
# 「首行单独一帧、其余每行各一帧」，直接整体压缩会破坏首帧契约。
is_plaintext_jsonl() {
  local f="$1"
  [ -f "$f" ] || return 1
  case "$f" in
    *.zstd) return 1 ;;
  esac
  # 首字节为 '{' 即视为明文 JSONL
  local b
  b="$("$NODE_BIN" -e 'const fs=require("fs");const fd=fs.openSync(process.argv[1],"r");const b=Buffer.alloc(1);fs.readSync(fd,b,0,1,0);fs.closeSync(fd);process.stdout.write(b[0]===0x7b?"y":"n")' "$f" 2>/dev/null)"
  [ "$b" = "y" ]
}

# 把明文 jsonl 按行成帧压缩为 zstd（首行 = 第一帧）
plaintext_to_zstd() {
  local src="$1" dst="$2"
  "$NODE_BIN" -e '
    const fs = require("fs"), zlib = require("zlib");
    const [src, dst] = process.argv.slice(1);
    const text = fs.readFileSync(src, "utf8");
    const lines = text.split("\n");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    if (!lines.length) { console.error("  ✗ 空文件"); process.exit(1); }
    let head;
    try { head = JSON.parse(lines[0]); }
    catch (e) { console.error("  ✗ 首行非合法 JSON"); process.exit(1); }
    if (head.type !== "session") { console.error("  ✗ 首行不是 session header"); process.exit(1); }
    const out = [];
    const frame = (str) => zlib.zstdCompressSync(Buffer.from(str + "\n", "utf8"));
    out.push(frame(lines[0]));                    // 首行单独成帧（契约要求）
    for (let i = 1; i < lines.length; i++) {
      if (lines[i] === "") continue;
      out.push(frame(lines[i]));                  // 其余每行各一帧（v0 布局）
    }
    fs.writeFileSync(dst, Buffer.concat(out));
    console.log("  ✓ 明文转 zstd: " + lines.length + " 行 → " + out.length + " 帧");
  ' "$src" "$dst"
}

# ---------- 格式体检 ----------
# 校验：zstd 可解 / 首帧恰好一行 header / header 含 id 与 version / 统计行数与帧数
check_artifact() {
  local f="$1"
  [ -f "$f" ] || { echo "  ✗ 文件不存在: $f" >&2; return 1; }
  "$NODE_BIN" -e '
    const fs = require("fs"), zlib = require("zlib");
    const p = process.argv[1];
    const buf = fs.readFileSync(p);
    const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
    // 统计 zstd frame 数（magic 出现次数）
    let frames = 0, pos = 0;
    while (true) {
      const i = buf.indexOf(MAGIC, pos);
      if (i < 0) break;
      frames++; pos = i + 4;
    }
    // 首帧边界
    const second = buf.indexOf(MAGIC, 1);
    const frame1 = second > 0 ? buf.subarray(0, second) : buf;
    let head, firstLines;
    try {
      firstLines = zlib.zstdDecompressSync(frame1).toString("utf8");
    } catch (e) {
      console.error("  ✗ 首帧解压失败: " + e.message); process.exit(1);
    }
    const nl = (firstLines.match(/\n/g) || []).length;
    if (nl !== 1 || !firstLines.endsWith("\n")) {
      console.error("  ✗ 首帧不是恰好一行 header（换行数=" + nl + "）");
      console.error("    这是 zstd 整体重压缩导致的多帧合并；须只重建首帧。");
      process.exit(1);
    }
    try { head = JSON.parse(firstLines.trim()); }
    catch (e) { console.error("  ✗ header 非合法 JSON"); process.exit(1); }
    if (head.type !== "session" || !head.id) {
      console.error("  ✗ header 缺少 type/id 字段"); process.exit(1);
    }
    console.log("  ✓ 首帧契约满足（恰好一行 header）");
    console.log("    frame 数 : " + frames);
    console.log("    id       : " + head.id);
    console.log("    版本     : v" + head.version);
    console.log("    cwd      : " + (head.cwd || "(无)"));
    console.log("    createdAt: " + head.createdAt);
  ' "$f"
}

# ---------- 重建首帧（只换 header 行，其余字节原样） ----------
# 这是修复「多帧合并」的正确姿势：新首帧 + 原第2帧起的全部原始字节
rebuild_first_frame() {
  local src="$1" dst="$2" newcwd="$3"
  "$NODE_BIN" -e '
    const fs = require("fs"), zlib = require("zlib"), path = require("path");
    const [src, dst, newcwd] = process.argv.slice(1);
    const buf = fs.readFileSync(src);
    const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
    const second = buf.indexOf(MAGIC, 1);
    if (second <= 0) { console.error("  ✗ 未找到第二个 frame（非多帧布局）"); process.exit(1); }
    const frame1 = buf.subarray(0, second), rest = buf.subarray(second);
    const headRaw = zlib.zstdDecompressSync(frame1).toString("utf8");
    const lines = headRaw.split("\n");
    if (lines.length < 2 || lines[1] !== "") { console.error("  ✗ 首帧不是单行"); process.exit(1); }
    const head = JSON.parse(lines[0]);
    const before = head.cwd;
    head.cwd = newcwd;
    const line = Buffer.from(JSON.stringify(head) + "\n", "utf8");
    const newFrame1 = zlib.zstdCompressSync(line, { params: { [zlib.constants.ZSTD_c_compressionLevel]: 3 } });
    fs.writeFileSync(dst, Buffer.concat([newFrame1, rest]));
    console.log("  原 cwd: " + before);
    console.log("  新 cwd: " + newcwd);
    console.log("  首帧 " + frame1.length + "B → " + newFrame1.length + "B；其余 " + rest.length + "B 原样保留");
  ' "$src" "$dst" "$newcwd" || return 1
}

# ---------- 列会话 ----------
do_list() {
  local home="$1"
  local sroot="$home/sessions"
  [ -d "$sroot" ] || { echo "  ✗ 无 sessions 目录: $sroot" >&2; return 1; }
  echo "DSH_HOME: $home"
  echo "sessions : $sroot"
  echo ""
  local d name bad=0
  for d in "$sroot"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      --*--) ;;
      *) echo "  ⚠ 非法目录（将导致激活失败）: $name"; bad=1; continue ;;
    esac
    local sid
    for sid in "$d"*/; do
      [ -d "$sid" ] || continue
      local sname gens="" g
      sname="$(basename "$sid")"
      for g in "$sid"session*.jsonl.zstd "$sid"session*.jsonl; do
        [ -f "$g" ] && gens="$gens $(basename "$g")"
      done
      [ -n "$gens" ] && printf '  %-52s %s\n' "$sname" "$gens"
    done
  done
  [ "$bad" -eq 1 ] && echo "" && echo "  → 请把上述非法目录移出 sessions/（脚本 --fix-layout 可代劳）"
  return 0
}

# ---------- 布局修复：把 sessions/ 根下的裸条目移出 ----------
do_fix_layout() {
  local home="$1"
  local sroot="$home/sessions"
  local bdir="$(dirname "$home")/session-backups"
  local moved=0 name
  [ -d "$sroot" ] || return 0
  for name in $(ls "$sroot" 2>/dev/null); do
    case "$name" in
      --*--) continue ;;
    esac
    [ -e "$sroot/$name" ] || continue
    mkdir -p "$bdir"
    mv "$sroot/$name" "$bdir/$name.$(date +%Y%m%d-%H%M%S)" && {
      echo "  → 已移出: $name → $bdir/"
      moved=$((moved+1))
    }
  done
  [ "$moved" -eq 0 ] && echo "  ✓ 布局正常，无非法条目" || echo "  ✓ 移出 $moved 项"
}

# ---------- 双路径自动导入：源 → 目标 DSH_HOME ----------
# 源可以是：
#   * 单个 session.jsonl / session.jsonl.zstd 文件
#   * 会话导出包解出的目录（含 session.jsonl + subagents/*/session.jsonl）
# 自动从 header 推导 id 与 cwd（cwd 改写为目标 home 下的同名工作区），
# 并把主会话与全部 subagent 会话一并投放。
derive_cwd_target() {
  # 把源 cwd 的「工作区名」映射到目标 home 下；无法映射时落到工作区根
  local srccwd="$1" dshhome="$2"
  local tail_name
  tail_name="$(basename "$srccwd")"
  local home_root
  home_root="$(dirname "$dshhome")"
  if [ -n "$tail_name" ] && [ -d "$home_root/$tail_name" ]; then
    echo "$home_root/$tail_name"
  elif [ "$tail_name" = "工作区" ] || [ -z "$tail_name" ]; then
    echo "$home_root/工作区"
  else
    # 目标 home 下无同名目录 → 用工作区根（最通用）
    [ -d "$home_root/工作区" ] && echo "$home_root/工作区" || echo "$home_root"
  fi
}

do_import_auto() {
  local src="$1" dshhome="$2"
  local sroot="$dshhome/sessions"
  local bdir="$(dirname "$dshhome")/session-backups"
  local stamp="$(date +%Y%m%d-%H%M%S)"

  [ -d "$dshhome" ] || { echo "  ✗ 目标 DSH_HOME 不存在: $dshhome" >&2; return 1; }

  # 展开源：文件 → 直接；目录 → session.jsonl + subagents/*/session.jsonl
  local main="" subs=()
  if [ -f "$src" ]; then
    main="$src"
  elif [ -d "$src" ]; then
    for cand in "$src/session.jsonl" "$src/session.jsonl.zstd"; do
      [ -f "$cand" ] && { main="$cand"; break; }
    done
    [ -z "$main" ] && { echo "  ✗ 目录中未找到 session.jsonl[.zstd]: $src" >&2; return 1; }
    local sd
    for sd in "$src/subagents"/*/; do
      [ -d "$sd" ] || continue
      for cand in "$sd/session.jsonl" "$sd/session.jsonl.zstd"; do
        [ -f "$cand" ] && { subs+=("$cand"); break; }
      done
    done
  else
    echo "  ✗ 源不存在: $src" >&2; return 1
  fi

  echo "源主会话 : $main"
  echo "子会话数 : ${#subs[@]}"
  echo "目标 home: $dshhome"
  echo ""

  # 读主会话 header
  local meta
  meta="$("$NODE_BIN" -e '
    const fs=require("fs"),zlib=require("zlib");
    const p=process.argv[1];
    let text;
    if(p.endsWith(".zstd")) text=zlib.zstdDecompressSync(fs.readFileSync(p)).toString("utf8");
    else text=fs.readFileSync(p,"utf8");
    const head=JSON.parse(text.split("\n")[0]);
    if(head.type!=="session"){console.error("首行不是 session header");process.exit(1);}
    process.stdout.write(JSON.stringify({id:head.id,cwd:head.cwd}));
  ' "$main")" || return 1
  local sid srccwd newcwd
  sid="$("$NODE_BIN" -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$meta")"
  srccwd="$("$NODE_BIN" -e 'process.stdout.write(JSON.parse(process.argv[1]).cwd||"")' "$meta")"
  newcwd="$(derive_cwd_target "$srccwd" "$dshhome")"

  echo "会话 id  : $sid"
  echo "源 cwd   : $srccwd"
  echo "目标 cwd : $newcwd"
  echo ""

  # 主会话投放
  echo "── 主会话 ──"
  local enc target
  enc="$(encode_cwd "$newcwd")"
  target="$sroot/$enc/$sid"

  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    cp -a "$target" "$bdir/${sid}.before-import-$stamp" 2>/dev/null && \
      echo "  覆盖前已备份 → $bdir/${sid}.before-import-$stamp"
  fi
  mkdir -p "$target"

  local worksrc="$main" conv=""
  if is_plaintext_jsonl "$main"; then
    conv="$(dirname "$main")/.conv.$$.zstd"
    plaintext_to_zstd "$main" "$conv" || return 1
    worksrc="$conv"
  fi
  local tmp="$target/.session.incoming.zstd"
  rebuild_first_frame "$worksrc" "$tmp" "$newcwd" || return 1
  mv -f "$tmp" "$target/session.jsonl.zstd" || return 1
  [ -n "$conv" ] && rm -f "$conv"
  # 移走既有 v3，确保重新迁移
  [ -f "$target/session.v3.jsonl.zstd" ] && \
    mv "$target/session.v3.jsonl.zstd" "$bdir/${sid}.v3-prev-$stamp" 2>/dev/null && \
    echo "  既有 v3 已移出（将重新迁移）"
  [ -f "$target/session.lock" ] && rm -f "$target/session.lock"
  check_artifact "$target/session.jsonl.zstd" | sed 's/^/  /'

  # 子会话投放
  if [ "${#subs[@]}" -gt 0 ]; then
    echo ""
    echo "── 子会话（subagents）──"
    local sf ssub dir nm sidir
    for sf in "${subs[@]}"; do
      nm="$(basename "$(dirname "$sf")")"      # subagent 目录名 = 子会话 id
      sidir="$target/subagents/$nm"
      mkdir -p "$sidir"
      local w2="$sf" c2=""
      if is_plaintext_jsonl "$sf"; then
        c2="$(dirname "$sf")/.conv2.$$.zstd"
        plaintext_to_zstd "$sf" "$c2" >/dev/null || { echo "  ✗ $nm 转码失败"; continue; }
        w2="$c2"
      fi
      # 子会话 header 里的 cwd 保持与主会话一致
      rebuild_first_frame "$w2" "$sidir/session.jsonl.zstd" "$newcwd" >/dev/null 2>&1         || cp -f "$w2" "$sidir/session.jsonl.zstd"
      [ -n "$c2" ] && rm -f "$c2"
      echo "  ✓ $nm"
    done
  fi

  echo ""
  echo "完成。落盘目录: $target"
  echo "提醒：需 DSH 启动后打开会话以触发 v0→v1→v2→v3 迁移。"
}

# ---------- 投放 ----------
do_install() {
  local home="$1" src="$2" sid="$3" newcwd="$4"
  local sroot="$home/sessions"
  local bdir="$(dirname "$home")/session-backups"
  local stamp="$(date +%Y%m%d-%H%M%S)"

  echo "[1/5] 源文件体检"
  if is_plaintext_jsonl "$src"; then
    echo "  明文 jsonl（DSH compression=zstd，投放时自动转码）"
    "$NODE_BIN" -e '
      const fs=require("fs");
      const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
      const head=JSON.parse(lines[0]);
      if(head.type!=="session"){console.error("  ✗ 首行不是 session header");process.exit(1);}
      console.log("    ✓ 首行是 session header");
      console.log("    行数: "+lines.length+"  id: "+head.id+"  版本: v"+head.version);
    ' "$src" || return 1
  else
    check_artifact "$src" || return 1
  fi

  echo ""
  echo "[2/5] 确定目标目录"
  local enc target
  enc="$(encode_cwd "$newcwd")"
  target="$sroot/$enc/$sid"
  echo "  cwd   : $newcwd"
  echo "  编码  : $enc"
  echo "  目标  : $target"

  echo ""
  echo "[3/5] 备份既有 generation（如存在）"
  if [ -d "$target" ]; then
    mkdir -p "$bdir"
    cp -a "$target" "$bdir/${sid}.before-install-$stamp" && echo "  → 备份: $bdir/${sid}.before-install-$stamp"
  else
    echo "  （目标目录不存在，新建）"
  fi

  echo ""
  echo "[4/5] 重写首帧 cwd 并投放"
  mkdir -p "$target"
  local tmp="$target/.session.incoming.zstd"
  local worksrc="$src"
  if is_plaintext_jsonl "$src"; then
    echo "  源为明文 jsonl（DSH 此处 compression=zstd，需转码）"
    local conv="$(dirname "$src")/.converted.$$.zstd"
    plaintext_to_zstd "$src" "$conv" || return 1
    worksrc="$conv"
  fi
  rebuild_first_frame "$worksrc" "$tmp" "$newcwd" || return 1
  [ "$worksrc" != "$src" ] && rm -f "$worksrc"
  mv -f "$tmp" "$target/session.jsonl.zstd" || return 1
  # 移除会阻碍自动迁移的既有 v3 generation（若有），改名保留
  if [ -f "$target/session.v3.jsonl.zstd" ]; then
    mv "$target/session.v3.jsonl.zstd" "$bdir/${sid}.v3-prev-$stamp" 2>/dev/null \
      && echo "  → 既有 v3 generation 已移出（避免跳过迁移）"
  fi
  # 清理可能残留的锁
  [ -f "$target/session.lock" ] && rm -f "$target/session.lock" && echo "  → 已清理 session.lock"

  echo ""
  echo "[5/5] 投放结果体检"
  check_artifact "$target/session.jsonl.zstd" || return 1
  echo ""
  echo "  落盘: $target/session.jsonl.zstd"
  echo "  属主: 请确认与 DSH 运行身份一致（脚本不假设用户）"
  echo ""
  echo "  提醒：工作区登记（workspace.json）与首次迁移需 DSH 完成——"
  echo "        启动 DSH 并打开该会话，持久化层会自动跑 v0→v1→v2→v3。"
}

# ---------- 回滚 ----------
do_rollback() {
  local home="$1" name="$2"
  local bdir="$(dirname "$home")/session-backups"
  echo "备份目录: $bdir"
  echo ""
  ls -la "$bdir" 2>/dev/null | tail -20
  echo ""
  if [ -n "$name" ] && [ -e "$bdir/$name" ]; then
    echo "恢复: $name"
    echo "  （请手动确认目标会话目录后执行 cp -a，脚本不自动覆盖线上数据）"
  else
    echo "用法: --rollback <备份名>  （备份名见上表）"
  fi
}

# ---------- 参数解析 ----------
MODE=""
ARG_HOME=""; ARG_IN=""; ARG_ID=""; ARG_CWD=""; ARG_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)       MODE="list"; shift ;;
    --check)      MODE="check"; ARG_IN="${2:-}"; shift 2 ;;
    --fix-layout) MODE="fix"; shift ;;
    --cwd)        ARG_CWD="${2:-}"; shift 2 ;;
    --in)         ARG_IN="${2:-}"; shift 2 ;;
    --id)         ARG_ID="${2:-}"; shift 2 ;;
    --home)       ARG_HOME="${2:-}"; shift 2 ;;
    --rollback)   MODE="rollback"; ARG_NAME="${2:-}"; shift 2 ;;
    --install)    MODE="install"; shift ;;
    --import)
                  # 双路径用法：--import <源文件|源目录> <目标 DSH_HOME>
                  MODE="import2"
                  ARG_IN="${2:-}"; ARG_HOME="${3:-}"; shift 3 ;;
    -h|--help)    MODE="help"; shift ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

# 未显式指定 MODE 时，凭 --in/--id/--cwd 三件套推断为投放模式
if [ -z "$MODE" ] && [ -n "$ARG_IN" ] && [ -n "$ARG_ID" ] && [ -n "$ARG_CWD" ]; then
  MODE="install"
fi

DSH_HOME_RESOLVED="${ARG_HOME:-$(detect_home || true)}"

case "${MODE:-}" in
  import2)
    [ -n "$ARG_IN" ]  || { echo "--import 需要 <源文件|源目录>" >&2; exit 2; }
    [ -n "$ARG_HOME" ] || { echo "--import 需要 <目标 DSH_HOME>" >&2; exit 2; }
    do_import_auto "$ARG_IN" "$ARG_HOME"
    ;;
  install)
    [ -n "$DSH_HOME_RESOLVED" ] || { echo "未定位到 DSH_HOME，请用 --home 指定" >&2; exit 1; }
    [ -n "$ARG_CWD" ] || { echo "投放需要 --cwd <新cwd>" >&2; exit 2; }
    [ -n "$ARG_ID" ]  || { echo "投放需要 --id <会话id>" >&2; exit 2; }
    [ -n "$ARG_IN" ]  || { echo "投放需要 --in <源文件>" >&2; exit 2; }
    do_install "$DSH_HOME_RESOLVED" "$ARG_IN" "$ARG_ID" "$ARG_CWD"
    ;;
  help|"")
    sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'
    ;;
  list)
    [ -n "$DSH_HOME_RESOLVED" ] || { echo "未定位到 DSH_HOME，请用 --home 指定" >&2; exit 1; }
    do_list "$DSH_HOME_RESOLVED"
    ;;
  fix)
    [ -n "$DSH_HOME_RESOLVED" ] || { echo "未定位到 DSH_HOME，请用 --home 指定" >&2; exit 1; }
    do_fix_layout "$DSH_HOME_RESOLVED"
    ;;
  check)
    [ -n "$ARG_IN" ] || { echo "--check 需要文件路径" >&2; exit 2; }
    if is_plaintext_jsonl "$ARG_IN"; then
      echo "  明文 jsonl（DSH compression=zstd 时投放前会自动转码）"
      "$NODE_BIN" -e '
        const fs=require("fs");
        const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
        const head=JSON.parse(lines[0]);
        console.log("    ✓ 首行是 session header");
        console.log("    行数     : "+lines.length);
        console.log("    id       : "+head.id);
        console.log("    版本     : v"+head.version);
        console.log("    cwd      : "+(head.cwd||"(无)"));
      ' "$ARG_IN"
    else
      check_artifact "$ARG_IN"
    fi
    ;;
  rollback)
    [ -n "$DSH_HOME_RESOLVED" ] || { echo "未定位到 DSH_HOME，请用 --home 指定" >&2; exit 1; }
    do_rollback "$DSH_HOME_RESOLVED" "$ARG_NAME"
    ;;
  install)
    : ;;
esac

