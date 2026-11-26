#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ci-plan.py — CI 变化检测与平台调度计划（供 build.yml 的 discover job 调用）。

设计意图：
  · 平台清单来自 build/config/platforms.json（注册表驱动）：新增产物平台只加一条配置，
    workflow 不用改（matrix 由本脚本输出的 JSON 展开）。
  · 每个平台声明 watch 路径（glob），本脚本用 git diff 判断「所属部分是否有变化」，
    没变化的平台在 CI 里空跑跳过 —— 这就是「动态执行」。
  · dry_run 只输出计划、不触发任何构建，用于验证判定逻辑（一次 1 分钟内跑完）。

输出（--format json，供 GitHub Actions 的 fromJSON 消费）：
  {
    "platforms": [
      {"name":"spk","desc":"…","changed":true,"reason":"build/spk/pack-spk.sh",
       "runner":"ubuntu-24.04","build":"./build/spk/pack-spk.sh",
       "artifacts":["build/staging/*.spk"],"publish":"release","needs_target":true}
    ],
    "need_target": true,
    "target_reason": "spk/fpk 有变化",
    "changed_files": 3,
    "base": "abc1234",
    "head": "def5678",
    "mode": "diff|force-all|no-baseline"
  }

判定基准（mode）：
  · diff          给定 base..head，按 diff 判定
  · force-all     强制全部构建（发版 tag / 手动勾选 force_all）
  · no-baseline   拿不到基准（首次、或 base 不存在）→ 保守全部构建

用法：
  ./scripts/ci-plan.py --arch x86_64 --format json
  ./scripts/ci-plan.py --arch arm64 --base <sha> --head <sha> --format json
  ./scripts/ci-plan.py --arch x86_64 --targets spk,docker --format json
  ./scripts/ci-plan.py --arch x86_64 --force-all --format text
  ./scripts/ci-plan.py --arch x86_64 --dry-run --format text
"""
from __future__ import print_function

import fnmatch
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(ROOT, "build", "config", "platforms.json")
DEFAULT_RUNNER = "ubuntu-24.04"


def load_registry():
    """返回 (platforms, target_watch)。target_watch 决定公共 target 是否必须重建。"""
    with open(REGISTRY, encoding="utf-8") as handle:
        data = json.load(handle)
    return (data.get("platforms") or []), ((data.get("target") or {}).get("watch") or [])


def git(*args):
    # 带 safe.directory：在 CIFS/SMB 挂载或属主不一致的机器上，裸 git 会报
    #   "dubious ownership" 而直接失败（实测本机就是这样，导致变化检测永远退化成
    #   no-baseline 全量构建）。CI 上无害，本地必需。
    result = subprocess.run(["git", "-c", "safe.directory=%s" % ROOT] + list(args),
                            cwd=ROOT, capture_output=True, text=True)
    return result.returncode, (result.stdout or "").strip(), (result.stderr or "").strip()


def changed_files(base, head):
    """返回 base..head 之间变更的文件列表；拿不到基准时返回 None。"""
    if not base or not head:
        return None
    code, out, _ = git("diff", "--name-only", base, head)
    if code != 0:
        return None
    return [line for line in out.split("\n") if line]


def matches(path, patterns):
    """glob 匹配，支持 ** 递归（fnmatch 的 * 会跨 /，这里按需放宽即可）。"""
    for pattern in patterns:
        if fnmatch.fnmatch(path, pattern):
            return True
        # "build/spk/**" 也应当匹配 "build/spk" 本身
        if pattern.endswith("/**") and path == pattern[:-3]:
            return True
    return False


def build_plan(arch, targets, force_all, base, head):
    registry, target_watch = load_registry()
    wanted = [t.strip() for t in (targets or "").split(",") if t.strip()]

    if force_all:
        files = None
        mode = "force-all"
    else:
        files = changed_files(base, head)
        mode = "diff" if files is not None else "no-baseline"

    # target 内容变了 → 所有依赖 target 的平台都必须重打（产物跟着变）
    if files is None:
        target_changed = True
        target_hit = []
    else:
        target_hit = [f for f in files if matches(f, target_watch)]
        target_changed = bool(target_hit)

    plan = []
    for entry in registry:
        name = entry.get("name") or ""
        if wanted and name not in wanted:
            continue
        needs_target = bool(entry.get("needs_target", True))
        if files is None:
            changed, reason = True, ("强制全量" if mode == "force-all" else "无可用基准，保守全量")
        else:
            hit = [f for f in files if matches(f, entry.get("watch") or [])]
            if hit:
                changed, reason = True, hit[0]
            elif needs_target and target_changed:
                # 自己没变，但公共 target 变了 —— 产物必然跟着变，必须重打
                changed, reason = True, "公共 target 变更（%s）" % target_hit[0]
            else:
                changed, reason = False, "所属部分无变化"
        runner_map = entry.get("runner") or {}
        plan.append({
            "name": name,
            "desc": entry.get("desc") or name,
            "changed": changed,
            "reason": reason,
            "runner": runner_map.get(arch) or runner_map.get("x86_64") or DEFAULT_RUNNER,
            "build": entry.get("build") or "",
            "artifacts": entry.get("artifacts") or [],
            "publish": entry.get("publish") or "release",
            "needs_target": bool(entry.get("needs_target", True)),
        })

    need_target = any(item["changed"] and item["needs_target"] for item in plan)
    changed_names = [item["name"] for item in plan if item["changed"]]
    return {
        "platforms": plan,
        "need_target": need_target,
        "target_changed": target_changed,
        "target_hit": (target_hit[:3] or (["（无基准，按需要重建处理）"] if files is None else [])),
        "target_reason": ("需要：" + ",".join(changed_names)) if need_target else "本次无需 target",
        "changed_files": len(files) if files is not None else -1,
        "base": base or "",
        "head": head or "",
        "mode": mode,
    }


def render_text(result, arch, dry_run):
    lines = []
    lines.append("═══ CI 计划（架构 %s%s）═══" % (arch, "，DRY-RUN 不执行" if dry_run else ""))
    lines.append("判定模式: %s   基准: %s → %s   变更文件: %s"
                 % (result["mode"], result["base"] or "-", result["head"] or "-",
                    result["changed_files"] if result["changed_files"] >= 0 else "未知"))
    lines.append("公共 target: %s（%s）" % ("需要" if result["need_target"] else "不需要",
                                          result["target_reason"]))
    if result.get("target_changed"):
        lines.append("target 内容: 变了 → 缓存会失效、必须重建（命中：%s）"
                     % ", ".join(result.get("target_hit") or []))
    else:
        lines.append("target 内容: 没变 → 可直接复用缓存（跳过 20 分钟编译）")
    lines.append("")
    lines.append("%-8s %-8s %-22s %s" % ("平台", "构建?", "runner", "原因"))
    for item in result["platforms"]:
        lines.append("%-8s %-8s %-22s %s"
                     % (item["name"], "✓ 是" if item["changed"] else "· 跳过",
                        item["runner"], item["reason"]))
    if dry_run:
        lines.append("")
        lines.append("（dry-run：以上仅为计划，未执行任何构建）")
    return "\n".join(lines)


def main():
    argv = sys.argv[1:]
    arch = "x86_64"
    targets = ""
    base = ""
    head = ""
    force_all = False
    dry_run = False
    fmt = "text"
    for index, arg in enumerate(argv):
        nxt = argv[index + 1] if len(argv) > index + 1 else ""
        if arg == "--arch":
            arch = nxt or arch
        elif arg == "--targets":
            targets = nxt
        elif arg == "--base":
            base = nxt
        elif arg == "--head":
            head = nxt
        elif arg == "--format":
            fmt = nxt or fmt
        elif arg == "--force-all":
            force_all = True
        elif arg == "--dry-run":
            dry_run = True

    result = build_plan(arch, targets, force_all, base, head)
    result["dry_run"] = dry_run
    if fmt == "json":
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(render_text(result, arch, dry_run))
    return 0


if __name__ == "__main__":
    sys.exit(main())
