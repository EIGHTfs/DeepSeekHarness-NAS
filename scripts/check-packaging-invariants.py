#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-packaging-invariants.py —— 打包/发布链路的关键不变量守卫。

每一条都对应 2026-09 ~ 2026-10 期间真实发生过的一次事故（括号内为现场），
把它们固化成"改坏了就红"的检查，避免同一个坑踩第二次。

检查项：
  1. pack-fpk.sh 的 cmd 钩子循环必须含 install_callback
     （少它 → fnOS 安装钩子不执行 → 数据目录/权限建不出来）
  2. pack-fpk.sh 必须调用 fix-runtime-deps.sh
     （SPK 一直有、FPK 一直缺 → FPK 缺 is-plain-obj/jsbi → 插件 failed to import）
  3. pack-fpk.sh 必须有 app.tgz 后处理：删软链 + uid/gid 归 root + 目录 755/文件 644
     （不删软链 → fnOS 解压设 ACL 失败 → 「设置目录权限失败」）
  4. pack-fpk.sh 必须生成 links.tar（软链专用清单，安装期精确还原）
  5. install_callback 必须用 tar 解 links.tar 还原（不能用逐行 ln -s 的文本清单）
  6. build/start.sh.example 的 portal 候选路径必须含飞牛路径
     （只认 DSM 的 /var/packages/… → 门户 url 永远 "/" → 套件点开打不开）
  7. build/start.sh.example 的临时目录首选必须是平台自带目录
     （写死 ${PID_DIR}/tmp → 应用数据目录里凭空多出 tmp/）
  8. build-common.sh 的 pnpm install 不得传空参数
     （空参数让 pnpm 11 解析错位 → 误报 Unknown option: 'frozen-lockfile'）
  9. build.yml 不得有 schedule（每日定时会破坏看门狗"成功后暂停 6 小时"口径）
 10. watch-official.yml 必须保留三条件（tag 未对齐 / 无构建在跑 / 距上次成功 ≥6h）
 11. 两条链路（SPK/FPK）的运行时补包调用必须同时存在（防止只修一条）
 12. 反代的「自动带 token」分支必须排在 403 之前
     （fnOS 套件打开与地址栏直连都发 sec-fetch-site=none，无法区分；
      403 在前 → 套件图标打开必吃 403，用户实测症状）

用法：./scripts/check-packaging-invariants.py [--verbose]
退出码 0 = 全部满足，1 = 有回归。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RED = "\033[31m" if sys.stdout.isatty() else ""
GRN = "\033[32m" if sys.stdout.isatty() else ""
RST = "\033[0m" if sys.stdout.isatty() else ""


def read(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.isfile(p):
        return None
    return io.open(p, encoding="utf-8", errors="replace").read()


def main():
    verbose = "--verbose" in sys.argv
    fails = []
    checks = []

    fpk = read("build/FPK/pack-fpk.sh") or ""
    spk = read("build/SPK/pack-spk.sh") or ""
    start = read("build/start.sh.example") or ""
    common = read("build/build-common.sh") or ""
    buildyml = read(".github/workflows/build.yml") or ""
    watch = read(".github/workflows/watch-official.yml") or ""

    def chk(no, ok, msg, hint=""):
        checks.append((no, ok, msg, hint))
        if not ok:
            fails.append("%s：%s" % (msg, hint) if hint else msg)

    # 1. 钩子循环含 install_callback
    m = re.search(r"for hook in ([^\n;]+)", fpk)
    hooks = m.group(1) if m else ""
    chk(1, "install_callback" in hooks,
        "pack-fpk.sh 钩子循环含 install_callback",
        "缺它 → fnOS 安装钩子不执行 → 权限/数据目录建不出来（当前: %s）" % hooks.strip()[:80])

    # 2 & 11. 运行时补包（★ 必须在 build-common.sh 里，CI 的打包 job 没有构建副本）
    chk(2, "fix-runtime-deps.sh" in common,
        "build-common.sh 在裁剪后调用 fix-runtime-deps.sh",
        "CI 打包 job 只有 target artifact，没有 BUILD_SRC → 放在打包器里会静默跳过"
        "（实测 CI 从未生效，导致缺 is-plain-obj/jsbi → 插件 failed to import）")
    chk(11, "fix-runtime-deps.sh" in common and
            ("fix-runtime-deps.sh" in spk or "fix-runtime-deps.sh" in fpk),
        "运行时补包在 build-common.sh（打包器里可留兜底）",
        "common=%s SPK=%s FPK=%s" % ("有" if "fix-runtime-deps.sh" in common else "无",
                                     "有" if "fix-runtime-deps.sh" in spk else "无",
                                     "有" if "fix-runtime-deps.sh" in fpk else "无"))

    # 3. app.tgz 后处理三要素
    has_strip = ("-type l -delete" in fpk) or ("find \"$_APP_STAGE\" -type l -delete" in fpk)
    has_root = "--owner=0" in fpk and "--group=0" in fpk
    has_mode = "chmod 755" in fpk and "chmod 644" in fpk
    chk(3, has_strip and has_root and has_mode,
        "pack-fpk.sh 有 app.tgz 后处理（删软链/uid-gid 归 root/755-644）",
        "删软链=%s root=%s 权限=%s；不删软链 → fnOS 解压设 ACL 失败" % (has_strip, has_root, has_mode))

    # 4. links.tar
    chk(4, "links.tar" in fpk,
        "pack-fpk.sh 生成 links.tar（软链专用清单）",
        "清单缺失 → 安装期无法还原软链 → 启动 ERR_MODULE_NOT_FOUND")

    # 5. install_callback 用 tar 解 links.tar
    tar_restore = ("tar -xf \"$_LK\"" in fpk) or ("tar -xf \"$LK\"" in fpk) or \
                  bool(re.search(r'tar\s+-xf\s+"?\$_?LK"?', fpk))
    ln_loop = "while IFS=" in fpk and "ln -sfn" in fpk
    chk(5, tar_restore and not ln_loop,
        "install_callback 用 tar 解 links.tar 还原软链",
        "实测逐行 ln -s 会错 542 条（含 @deepseek-ai/dsh）→ 插件挂；tar_restore=%s ln_loop=%s"
        % (tar_restore, ln_loop))

    # 6. portal 飞牛路径
    chk(6, ("SCRIPT_DIR/../ui/config" in start) and ("/var/apps/${APP_NAME}/target/ui/config" in start),
        "start.sh 的 portal 候选路径含飞牛路径",
        "只认 DSM 的 /var/packages/… → 门户 url 永远 \"/\" → 套件图标点开打不开")

    # 7. 临时目录首选平台目录
    chk(7, ("TRIM_PKGTMP" in start) and ("/var/apps/${APP_NAME}/tmp" in start),
        "start.sh 的临时目录优先用平台自带目录",
        "写死 ${PID_DIR}/tmp → 应用数据目录里多出 tmp/（用户口径不允许）")

    # 8. pnpm install 不得传空参数
    chk(8, "${1:+$1}" in common,
        "build-common.sh 的 pnpm install 不传空参数",
        "空参数让 pnpm 11 解析错位 → 误报 Unknown option: 'frozen-lockfile'（应写 ${1:+$1}）")

    # 9. build.yml 不得有 schedule
    chk(9, not re.search(r"^\s*schedule:\s*$", buildyml, re.M),
        "build.yml 无 schedule（每日定时不得复活）",
        "它会破坏看门狗「成功后暂停 6 小时」口径；触发应只剩 看门狗/手动/tag")

    # 10. 看门狗三条件
    ok_watch = ("in_progress" in watch) and ("21600" in watch or "6" in watch) and \
               ("tag" in watch) and ("releases" in watch or "Release" in watch)
    chk(10, ok_watch,
        "watch-official.yml 保留三条件（tag 未对齐/无构建在跑/距上次成功 ≥6h）",
        "应保留：官方 tag≠本仓 tag / 无构建在跑 / 距上次成功 ≥6 小时（21600s）")

    # 12. 反代里「自动带 token」必须排在 403 之前
    #     fnOS 套件图标打开与地址栏直连**都**发 sec-fetch-site=none，无法区分；
    #     403 若在前，从套件图标打开必吃 403（2026-10-09 用户实测症状：
    #     "套件没打开 url，url 不带 token" → 页面显示「请从套件图标打开」）。
    i_auto = start.find("autoAuthRedirect(clientReq, clientRes)")
    i_403 = start.find("clientRes.end(FORBIDDEN_PAGE)")
    chk(12, i_auto != -1 and i_403 != -1 and i_auto < i_403,
        "反代的「自动带 token」分支排在 403 之前",
        "autoAuth 位置=%s，403 位置=%s（前者必须更靠前；否则套件图标打开会吃 403）" % (i_auto, i_403))

    # 13. start.sh 必须含启动期自愈兜底（工作区链接 + links.tar）
    #     DSH 靠 node_modules/@deepseek-ai/* → packages/* 的工作区软链解析；任一环节漏掉
    #     就 ERR_MODULE_NOT_FOUND: Cannot find package '@deepseek-ai/dsh-app-boot'
    #     → 退出 code=1 → 守护反复重试 → 用户观感"启动卡很久"。
    chk(13, ("selfHealWorkspaceLinks" in start) and ("selfHealLinksTar" in start),
        "start.sh 含启动期自愈兜底（工作区链接 + links.tar）",
        "缺则安装期漏链时启动必失败并反复重试；两个函数与调用都要在")

    # 14. 反代必须有「陈旧 token 兜底」
    #     fnOS 桌面缓存上次的 URL（带旧 token）→ 重启后 token 变了 → DSH 401 →
    #     用户观感"套件打不开"，且每次重启复发。反代需把非当次 token 302 换成当次。
    chk(14, "陈旧 token" in start and "_tm[1] !== dshToken" in start,
        "反代含「陈旧 token 兜底」（非当次 token → 302 换成当次）",
        "缺则每次重启应用后，套件图标都会带着过期 token 打不开")

    # 15. 门户 url 必须【固定 "/"】（2026-10-10 实测，勿回退）
    #     实测：包内原版 url="/" → 飞牛应用中心「打开」按钮正常；
    #     启动期把 token 写进 url（"/?token=…"）→ 按钮点不开。
    #     对照能正常打开的 1Panel：它的 .url 条目里根本没有 url 字段。
    #     带 token 的免密由反代完成（局域网硬闸 → 无 token 自动带 → 陈旧 token 换当次）。
    chk(15, 'u[k].url = "/"' in start and 'url = "/?token=" + tok' not in start,
        "门户 url 固定为 /（token 不进门户文件，免密交给反代）",
        "写成 /?token=… 会让飞牛「打开」按钮点不开（实测）")


    # 输出
    for no, ok, msg, hint in checks:
        if ok:
            print("%s✓ [%2d] %s%s" % (GRN, no, msg, RST))
        else:
            print("%s✗ [%2d] %s%s" % (RED, no, msg, RST))
            if hint:
                print("        %s" % hint)
    print("═══ 结论 ═══")
    if fails:
        print("%s✗ %d 项打包不变量被破坏：%s" % (RED, len(fails), RST))
        for f in fails:
            print("   - %s" % f)
        return 1
    print("%s✓ %d 项打包不变量全部满足%s" % (GRN, len(checks), RST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
