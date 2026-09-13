#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
官方打包文档抓取脚本（SPK + FPK）

用途：把群晖 Synology 与飞牛 fnOS 的官方打包文档完整抓到本仓库，
      供离线查阅与打包实现对照（不依赖联网即可查规范）。
      官方文档是本项目的规范依据，凡打包字段有疑问一律以此为准。

输出（相对仓库根）：
  docs/官方文档/spk/   群晖 Synology Package Developer Guide 全部页面
  docs/官方文档/fpk/   飞牛 fnOS 应用开放平台全部页面
  各自含 index.md（目录）与 _meta.json（抓取元信息）

用法：
  python3 scripts/fetch-official-docs.py            # 抓两边
  python3 scripts/fetch-official-docs.py spk        # 只抓群晖
  python3 scripts/fetch-official-docs.py fpk        # 只抓飞牛

特性：
  - 幂等：重复运行覆盖同名文件，不产生副本
  - 断点友好：单页失败不中断整体，失败清单记录在 _meta.json
  - 正文提取：基于 HTMLParser 保留标题层级、嵌套列表、代码块、表格、引用
"""

import html
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_ROOT = os.path.join(WS, "docs", "官方文档")

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36 dsh-doc-fetcher")

# ── 群晖官方文档：入口页 → 侧边栏 href 全集 ────────────────────────────────
SYNO_BASE = "https://help.synology.com/developer-guide"
SYNO_ENTRY = SYNO_BASE + "/synology_package/info.html"

# ── 飞牛官方文档：种子页 + 同域爬取 ────────────────────────────────────────
FNOS_BASE = "https://developer.fnnas.com"
FNOS_SEEDS = [
    "/docs/guide/",
    "/docs/update-log/",
    "/docs/cli/fnpack/",
    "/api/overview/",
]
FNOS_MAX_PAGES = 200


def fetch(url, timeout=25):
    """抓取 URL，返回 (状态码, 文本)。失败返回 (None, 错误串)。"""
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            charset = r.headers.get_content_charset() or "utf-8"
            return r.status, raw.decode(charset, errors="ignore")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e)


# ══════════════════════════════════════════════════════════════════════════
#  HTML → Markdown（HTMLParser 实现：正确处理嵌套列表与行内强调）
# ══════════════════════════════════════════════════════════════════════════
class Markdownizer(HTMLParser):
    """把正文 HTML 片段转成结构清晰的 Markdown。

    设计要点：
      - 用标签栈而非正则替换，嵌套 <ul>/<li> 能正确缩进（官方 INFO 文档
        通篇是 h2 + 嵌套列表，正则会把层级压平、把 <strong> 当噪声剥掉）
      - <pre> 内文本原样保留（代码/配置示例是规范核心，不能动）
      - 表格转标准 Markdown 表；<blockquote> 转引用块
    """

    SKIP = {"script", "style", "svg", "button", "noscript", "iframe",
            "nav", "footer", "form", "select", "option"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks = []        # 完成的块
        self.cur = []           # 当前块行缓冲
        self.skip_depth = 0
        self.pre_buf = None     # <pre> 缓冲（非 None 表示在代码块内）
        self.lists = []         # [{'tag': 'ul'|'ol', 'n': int}, ...]
        self.quote = 0          # <blockquote> 嵌套深度
        self.table = None       # 表格行缓冲
        self.row = None
        self.cell = None

    # ---------- 输出辅助 ----------
    def _flush(self):
        text = "".join(self.cur)
        self.cur = []
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r" *\n *", "\n", text)
        text = text.strip()
        if not text:
            return
        if self.quote:
            text = "\n".join(("> " + ln if ln.strip() else ">") for ln in text.split("\n"))
        self.blocks.append(text)

    def _put(self, s):
        self.cur.append(s)

    def _newline(self):
        """确保当前行结束（避免把相邻块粘成一行）。"""
        if not self.cur or not "".join(self.cur).endswith("\n"):
            self._put("\n")

    # ---------- 标签 ----------
    def handle_starttag(self, tag, attrs):
        if self.pre_buf is not None:                 # <pre> 内部：只认 <br>
            if tag == "br":
                self.pre_buf.append("\n")
            return
        if tag in self.SKIP:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return

        if tag == "pre":
            self._flush()
            self.pre_buf = []
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._flush()
            self._newline()
            self._put("\n" + "#" * int(tag[1]) + " ")
        elif tag in ("ul", "ol"):
            self._flush()
            self.lists.append({"tag": tag, "n": 0})
        elif tag == "li":
            self._flush()
            depth = max(0, len(self.lists) - 1)
            marker = "- "
            if self.lists and self.lists[-1]["tag"] == "ol":
                self.lists[-1]["n"] += 1
                marker = "%d. " % self.lists[-1]["n"]
            self._put("\n" + "  " * depth + marker)
        elif tag == "blockquote":
            self._flush()
            self.quote += 1
        elif tag == "table":
            self._flush()
            self.table = []
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.cell = []
        elif tag == "br":
            self._put("\n")
        elif tag == "hr":
            self._flush()
            self.blocks.append("---")
        elif tag in ("p", "div", "section", "article", "dl", "dt", "dd"):
            self._flush()
        elif tag in ("strong", "b"):
            self._put("**")
        elif tag in ("em", "i"):
            self._put("*")
        elif tag == "code":
            self._put("`")

    def handle_endtag(self, tag):
        if self.pre_buf is not None:
            if tag == "pre":
                code = "".join(self.pre_buf).strip("\n")
                self.pre_buf = None
                self._flush()
                if code.strip():
                    self.blocks.append("```\n%s\n```" % code)
            return
        if tag in self.SKIP:
            if self.skip_depth:
                self.skip_depth -= 1
            return
        if self.skip_depth:
            return

        if tag in ("h1", "h2", "h3", "h4", "h5", "h6", "p",
                   "div", "section", "article", "dl", "dt", "dd", "li"):
            self._flush()
        elif tag in ("ul", "ol"):
            self._flush()
            if self.lists:
                self.lists.pop()
        elif tag == "blockquote":
            self._flush()
            self.quote = max(0, self.quote - 1)
        elif tag in ("td", "th"):
            txt = "".join(self.cell or [])
            txt = re.sub(r"\s+", " ", txt).strip().replace("|", "\\|")
            if self.row is not None:
                self.row.append(txt)
            self.cell = None
        elif tag == "tr":
            if self.table is not None and self.row:
                self.table.append(self.row)
            self.row = None
        elif tag == "table":
            self._flush()
            rows = [r for r in (self.table or []) if r]
            if rows:
                width = max(len(r) for r in rows)
                out = []
                for i, r in enumerate(rows):
                    cells = r + [""] * (width - len(r))
                    out.append("| " + " | ".join(cells) + " |")
                    if i == 0:
                        out.append("|" + "---|" * width)
                self.blocks.append("\n".join(out))
            self.table = None
        elif tag in ("strong", "b"):
            self._put("**")
        elif tag in ("em", "i"):
            self._put("*")
        elif tag == "code":
            self._put("`")

    def handle_data(self, data):
        if self.skip_depth:
            return
        if self.pre_buf is not None:
            self.pre_buf.append(data)
            return
        if self.cell is not None:
            self.cell.append(data)
            return
        self._put(data)

    def result(self):
        self._flush()
        md = "\n\n".join(b for b in self.blocks if b.strip())
        md = re.sub(r"\n{3,}", "\n\n", md)
        return md.strip()


def html_to_md(frag):
    if not frag:
        return ""
    p = Markdownizer()
    try:
        p.feed(frag)
        p.close()
    except Exception:
        # 兜底：解析异常时退回纯文本，保证正文不丢
        t = re.sub(r"<[^>]+>", " ", frag)
        return re.sub(r"\n{3,}", "\n\n", html.unescape(t)).strip()
    return p.result()


def clean_leading_breadcrumb(md):
    """去掉飞牛 Docusaurus 页首的面包屑（"- 开发指南 / - 应用入口 / 本页总览"）。"""
    lines = md.split("\n")
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s == "" or s.startswith("- ") or s == "本页总览" or s == "​":
            i += 1
            continue
        break
    return "\n".join(lines[i:]).strip()


def pick_title(md, fallback):
    """取正文第一个标题行作为标题（避免拿到面包屑等噪声）。"""
    m = re.search(r"^#{1,6}\s+(.+)$", md, re.M)
    if m:
        return m.group(1).strip()
    first = md.strip().split("\n", 1)[0].strip()
    return first[:80] if first else fallback


def syno_extract(htm):
    """群晖 GitBook：取 section.normal 正文容器。"""
    m = re.search(r'<section class="normal[^"]*"[^>]*>(.*?)</section>', htm, re.S)
    body = m.group(1) if m else ""
    body = re.sub(r'<div class="gitbook-link[^"]*">.*?</div>', "", body, flags=re.S)
    return html_to_md(body)


def fnos_extract(htm):
    """飞牛 Docusaurus：取 <article> 正文。"""
    m = re.search(r"<article[^>]*>(.*?)</article>", htm, re.S | re.I)
    body = m.group(1) if m else ""
    if not body:
        m = re.search(r'<div[^>]*class="[^"]*theme-doc-markdown[^"]*"[^>]*>(.*?)</div>\s*</div>',
                      htm, re.S | re.I)
        body = m.group(1) if m else ""
    md = html_to_md(body)
    return clean_leading_breadcrumb(md)


# ══════════════════════════════════════════════════════════════════════════
#  群晖：从入口页拿全部侧边栏链接
# ══════════════════════════════════════════════════════════════════════════
def syno_page_list():
    code, htm = fetch(SYNO_ENTRY)
    if code != 200:
        print("  [!] 入口页抓取失败: %s" % code)
        return []
    urls = []
    for href in re.findall(r'href="([^"]+\.html)"', htm):
        if href.startswith(("http", "#", "mailto:")):
            continue
        full = urllib.parse.urljoin(SYNO_ENTRY, href)
        if "/developer-guide/" not in full:
            continue
        path = full.split("/developer-guide/", 1)[1]
        if path not in urls:
            urls.append(path)
    return sorted(urls)


def write_page(outdir, name, md, url, fetched):
    title = pick_title(md, name)
    fm = ("---\n"
          "source: %s\n"
          "title: %s\n"
          "fetched: %s\n"
          "---\n\n" % (url, title.replace("\n", " "), fetched))
    with io.open(os.path.join(outdir, name + ".md"), "w", encoding="utf-8") as f:
        f.write(fm + md + "\n")
    return title


def do_syno():
    outdir = os.path.join(OUT_ROOT, "spk")
    os.makedirs(outdir, exist_ok=True)
    print("▶ 群晖官方文档 → docs/官方文档/spk/")
    pages = syno_page_list()
    if not pages:
        return {"ok": 0, "fail": ["入口页无链接"]}
    print("  发现 %d 个页面" % len(pages))

    fetched = time.strftime("%Y-%m-%d")
    ok, fail, index = 0, [], []
    for i, path in enumerate(pages, 1):
        url = "%s/%s" % (SYNO_BASE, path)
        code, htm = fetch(url)
        if code != 200:
            fail.append("%s (HTTP %s)" % (path, code))
            print("  [%d/%d] ✗ %s" % (i, len(pages), path))
            continue
        md = syno_extract(htm)
        if len(md.strip()) < 20:
            fail.append("%s (正文为空)" % path)
            print("  [%d/%d] ✗ %s 正文空" % (i, len(pages), path))
            continue
        name = path.replace("/", "__").replace(".html", "")
        title = write_page(outdir, name, md, url, fetched)
        index.append((path, name, title, url))
        ok += 1
        print("  [%d/%d] ✓ %s (%d 字符)" % (i, len(pages), path, len(md)))
        time.sleep(0.25)

    write_index(outdir, index, "Synology Package Developer Guide", SYNO_BASE, ok, fail)
    return {"ok": ok, "fail": fail}


# ══════════════════════════════════════════════════════════════════════════
#  飞牛：种子页 BFS 爬同域文档链接
# ══════════════════════════════════════════════════════════════════════════
def fnos_crawl():
    seen, queue, pages = set(), list(FNOS_SEEDS), []
    while queue and len(pages) < FNOS_MAX_PAGES:
        path = queue.pop(0)
        if path in seen:
            continue
        seen.add(path)
        code, htm = fetch(FNOS_BASE + path)
        if code != 200:
            continue
        pages.append((path, htm))
        for href in re.findall(r'href="(/[^"#?]*)"', htm):
            if not href.startswith(("/docs/", "/api/")):
                continue
            if href.endswith((".css", ".js", ".png", ".svg", ".ico", ".xml", ".json")):
                continue
            if href not in seen:
                queue.append(href)
        time.sleep(0.2)
    return pages


def do_fnos():
    outdir = os.path.join(OUT_ROOT, "fpk")
    os.makedirs(outdir, exist_ok=True)
    print("▶ 飞牛官方文档 → docs/官方文档/fpk/")
    pages = fnos_crawl()
    print("  爬取到 %d 个页面" % len(pages))

    fetched = time.strftime("%Y-%m-%d")
    ok, fail, index = 0, [], []
    for i, (path, htm) in enumerate(pages, 1):
        md = fnos_extract(htm)
        if len(md.strip()) < 20:
            fail.append("%s (正文为空)" % path)
            print("  [%d/%d] ✗ %s 正文空" % (i, len(pages), path))
            continue
        name = path.strip("/").replace("/", "__") or "index"
        url = FNOS_BASE + path
        title = write_page(outdir, name, md, url, fetched)
        index.append((path, name, title, url))
        ok += 1
        print("  [%d/%d] ✓ %s (%d 字符)" % (i, len(pages), path, len(md)))

    write_index(outdir, index, "飞牛 fnOS 应用开放平台文档", FNOS_BASE, ok, fail)
    return {"ok": ok, "fail": fail}


# ══════════════════════════════════════════════════════════════════════════
def write_index(outdir, index, source_name, base, ok, fail):
    """生成 index.md 目录 + _meta.json 元信息。"""
    lines = [
        "# %s（官方文档存档）" % source_name,
        "",
        "> 本目录由 `scripts/fetch-official-docs.py` 自动抓取，**请勿手工编辑**。",
        "> 重新抓取：`python3 scripts/fetch-official-docs.py`",
        "",
        "- 来源站点：%s" % base,
        "- 抓取时间：%s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "- 成功页面：%d" % ok,
        "",
        "## 页面索引",
        "",
        "| 原文路径 | 本地文件 | 标题 |",
        "|----------|----------|------|",
    ]
    for path, name, title, _url in sorted(index, key=lambda x: x[0]):
        lines.append("| `%s` | `%s.md` | %s |" % (path, name, title.replace("|", "\\|")))
    if fail:
        lines += ["", "## 抓取失败", ""] + ["- `%s`" % f for f in fail]
    lines.append("")
    with io.open(os.path.join(outdir, "index.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    meta = {
        "source": source_name,
        "base_url": base,
        "fetched_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ok": ok,
        "failed": fail,
        "pages": [{"path": p, "file": n + ".md", "title": t, "url": u}
                  for p, n, t, u in index],
    }
    with io.open(os.path.join(outdir, "_meta.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")


def main():
    which = sys.argv[1].lower() if len(sys.argv) > 1 else "all"
    if which not in ("all", "spk", "fpk"):
        print("用法: %s [all|spk|fpk]" % sys.argv[0])
        return 2

    results = {}
    if which in ("all", "spk"):
        results["spk"] = do_syno()
    if which in ("all", "fpk"):
        results["fpk"] = do_fnos()

    print("")
    print("═════════ 抓取结果 ═════════")
    total_fail = 0
    for k, v in results.items():
        print("  %s: 成功 %d 页，失败 %d 页" % (k.upper(), v["ok"], len(v["fail"])))
        total_fail += len(v["fail"])
    print("  输出目录: docs/官方文档/")
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
