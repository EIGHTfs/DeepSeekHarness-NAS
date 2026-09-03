#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix-dsh-bundle-patch-insert.py

把第三方 DSH 插件的 bundle `cordis.patch.yml` 从「顶层 - id 覆盖」改成「- insert 新建行」。

用户原话（2026-09-03）：
  「那是不是这两个插件仓库源代码就写的有问题」
  「直接改工作区，顺便检查下我远程dsh插件库是不是都写错了（写错了就转成私有先，以后改）」
  「帮忙把修复记忆固化skill。然后修复脚本传30801的dshnas仓库」

【原代码】无 insert 的 - id: git-push / skill-scoreboard，boot/dshmarket 当覆盖已有 loader 行。
【改为】顶层 - insert: 再带 id/name（与 dsh-cloud-workspaces / dshmarket 同款）。
【思路】基座没有这些 id → 市场 orphan「目标不存在 / patch target not found」。
        写文件走 fileinput + .bak + utf-8（python-fileinput-write）。

用法:
  python3 fix-dsh-bundle-patch-insert.py --dry-run
  python3 fix-dsh-bundle-patch-insert.py [路径 ...]
  python3 fix-dsh-bundle-patch-insert.py --profile-patch /path/to/profiles/web/cordis.patch.yml \\
      --override-ids git-push,skill-scoreboard

路径可以是单个插件目录、单个 yml，或工作区（扫描一级子目录的 cordis.patch.yml）。
缺省扫描 30801 工作区。
"""

from __future__ import annotations

import argparse
import fileinput
import sys
from pathlib import Path

DEFAULT_WORKSPACE = Path(
    "/vol1/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4/.dsh-home/工作区"
)

COMMENT_HEAD = """# 2026-09-03 修改：原代码注释保留
# 【原代码】无 insert 的顶层 - id（覆盖已有 loader 行）
# 【改为】顶层 insert 新建行（第三方 bundle patch 标准写法）
# 【用户原话】市场「目标不存在 / patch target not found」；「直接改工作区」
# 【思路】基座没有该 id，bundle 层打空。与 dsh-cloud-workspaces / dshmarket 同款。
"""


def is_top_insert_line(line: str) -> bool:
    return line.startswith("- insert:")


def is_top_id_line(line: str) -> bool:
    return line.startswith("- id:")


def classify_patch(text: str) -> str:
    """wrong | ok | empty | other"""
    code_lines = []
    for raw in text.splitlines():
        s = raw.rstrip("\n")
        if not s.strip() or s.lstrip().startswith("#"):
            continue
        code_lines.append(s)
    if not code_lines:
        return "empty"
    has_insert = any(is_top_insert_line(s) for s in code_lines)
    has_top_id = any(is_top_id_line(s) for s in code_lines)
    if has_insert and not has_top_id:
        return "ok"
    if has_top_id and not has_insert:
        return "wrong"
    if has_top_id and has_insert:
        return "mixed"
    return "other"


def split_top_items(lines: list[str]) -> list[list[str]]:
    """按顶层 `- ` 切开（含其注释挂在下一项之前）。"""
    items: list[list[str]] = []
    cur: list[str] = []
    pending_comments: list[str] = []
    started = False
    for line in lines:
        if line.startswith("- ") and not line.startswith("- insert:"):
            if started:
                items.append(cur)
            cur = pending_comments + [line]
            pending_comments = []
            started = True
        elif not started:
            if line.strip().startswith("#") or not line.strip():
                pending_comments.append(line)
            else:
                pending_comments.append(line)
        else:
            cur.append(line)
    if started:
        items.append(cur)
    elif pending_comments:
        items.append(pending_comments)
    return items


def wrap_item_as_insert(item_lines: list[str]) -> list[str]:
    body: list[str] = []
    comments: list[str] = []
    seen_dash = False
    for line in item_lines:
        if not seen_dash:
            if line.startswith("- "):
                seen_dash = True
                body.append(line)
            else:
                comments.append(line)
        else:
            body.append(line)
    if not body:
        return item_lines

    out: list[str] = []
    for c in comments:
        if c.strip():
            out.append(c if c.lstrip().startswith("#") else "# " + c)
        else:
            out.append(c)
    out.append("- insert:")
    for line in body:
        if line.startswith("- "):
            out.append("    " + line)
        elif line.startswith("  "):
            out.append("    " + line)
        elif not line.strip():
            out.append(line)
        elif line.lstrip().startswith("#"):
            out.append("    " + line)
        else:
            out.append("    " + line)
    return out


def convert_text(text: str) -> str:
    kind = classify_patch(text)
    if kind != "wrong":
        return text
    raw_lines = text.splitlines()
    # 丢掉文件头里「纯旧内容」；转换后统一加 COMMENT_HEAD
    items = split_top_items(raw_lines)
    wrapped: list[str] = []
    for item in items:
        if any(ln.startswith("- id:") for ln in item):
            wrapped.extend(wrap_item_as_insert(item))
        else:
            wrapped.extend(item)
    body = "\n".join(wrapped).rstrip() + "\n"
    return COMMENT_HEAD + body


def write_via_fileinput(path: Path, new_text: str) -> None:
    if not new_text.endswith("\n"):
        new_text += "\n"
    first = True
    with fileinput.input(files=[str(path)], inplace=True, backup=".bak", encoding="utf-8") as fh:
        for _line in fh:
            if first:
                print(new_text, end="")
                first = False


def collect_patch_files(paths: list[Path]) -> list[Path]:
    found: list[Path] = []
    for p in paths:
        if p.is_file() and p.name == "cordis.patch.yml":
            found.append(p)
            continue
        if p.is_dir():
            direct = p / "cordis.patch.yml"
            if direct.is_file():
                found.append(direct)
                continue
            for child in sorted(p.iterdir()):
                cand = child / "cordis.patch.yml"
                if child.is_dir() and cand.is_file():
                    found.append(cand)
    # 去重保序
    out: list[Path] = []
    seen = set()
    for f in found:
        key = str(f.resolve())
        if key in seen:
            continue
        seen.add(key)
        out.append(f)
    return out


def convert_profile_inserts_to_overrides(text: str, ids: set[str]) -> str:
    """把用户层里对指定 id 的 `- insert:` 块改成顶层 `- id:` 覆盖。"""
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    changed = False
    note = (
        "# 2026-09-03 修改：bundle 层已 insert 下列 id，用户层改为按 id 覆盖，避免 duplicate-id 双挂"
    )
    while i < len(lines):
        line = lines[i]
        if line.startswith("- insert:"):
            # 预读下一块，看第一个 `- id:`
            j = i + 1
            block = [line]
            while j < len(lines) and not (
                lines[j].startswith("- insert:") or lines[j].startswith("- id:")
            ):
                block.append(lines[j])
                j += 1
            inner_id = None
            for b in block:
                s = b.strip()
                if s.startswith("- id:"):
                    inner_id = s.split(":", 1)[1].strip()
                    break
            if inner_id in ids:
                if not changed:
                    out.append(note)
                    changed = True
                # 去掉 insert 行，把 `    - id:` 升成 `- id:`，其余少 4 空格
                for b in block[1:]:
                    if b.startswith("    "):
                        out.append(b[4:])
                    else:
                        out.append(b)
                i = j
                continue
            out.extend(block)
            i = j
            continue
        out.append(line)
        i += 1
    return "\n".join(out).rstrip() + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fix DSH plugin cordis.patch.yml to use insert")
    parser.add_argument("paths", nargs="*", type=Path, help="plugin dir / yml / workspace")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--profile-patch", type=Path, help="profile cordis.patch.yml 用户层")
    parser.add_argument(
        "--override-ids",
        default="git-push,skill-scoreboard",
        help="用户层要从 insert 改成覆盖的 id，逗号分隔",
    )
    args = parser.parse_args(argv)

    targets = args.paths or [DEFAULT_WORKSPACE]
    files = collect_patch_files(targets)
    if not files:
        print("没有找到 cordis.patch.yml", file=sys.stderr)
        # 仍可能只改 profile
    print(f"扫描 {len(files)} 个 cordis.patch.yml")
    changed = 0
    skipped = 0
    for path in files:
        text = path.read_text(encoding="utf-8")
        kind = classify_patch(text)
        rel = str(path)
        if kind != "wrong":
            print(f"  skip {kind:6}  {rel}")
            skipped += 1
            continue
        new = convert_text(text)
        if args.dry_run:
            print(f"  DRY  wrong → insert  {rel}")
            changed += 1
            continue
        write_via_fileinput(path, new)
        bak = Path(str(path) + ".bak")
        print(f"  FIX  {rel}  bak={bak.exists()}")
        changed += 1

    if args.profile_patch:
        pp = args.profile_patch
        ids = {x.strip() for x in args.override_ids.split(",") if x.strip()}
        old = pp.read_text(encoding="utf-8")
        new = convert_profile_inserts_to_overrides(old, ids)
        if new != old:
            if args.dry_run:
                print(f"  DRY  profile override  {pp}")
            else:
                write_via_fileinput(pp, new)
                print(f"  FIX  profile  {pp}")
            changed += 1
        else:
            print(f"  skip profile (无需改)  {pp}")
            skipped += 1

    print(f"完成 changed={changed} skipped={skipped} dry_run={args.dry_run}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
