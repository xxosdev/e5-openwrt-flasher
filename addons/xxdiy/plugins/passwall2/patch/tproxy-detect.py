#!/usr/bin/env python3
"""修 passwall2 对「透明代理组件」的误判。

E5 的内核（6.18.54-e5-sleep14-charles）把 nft_tproxy / nft_socket / nft_redir
都编进了内核（=y），所以 `lsmod` 里永远看不到它们。passwall2 靠 lsmod 判断，
于是认为「缺组件」：

  client/global.lua  -> Localhost Proxy / Client Proxy 变成灰色禁用的复选框，
                        外加一行红字 "Missing components, transparent proxy is unavailable."
  client/other.lua   -> 整个「TCP Proxy Way」下拉框直接消失，连 REDIRECT/TPROXY
                        都没得选

两处是**同一行代码**，所以一起替换。

做法是插一个哨兵文件判断，而不是写死 true：

    local _xxdiy_builtin = io.open("/etc/e5/xxdiy/nft-tproxy-builtin")
    if _xxdiy_builtin then _xxdiy_builtin:close() end
    if _xxdiy_builtin or (mods:find(...) ...) then

这样：
  * 幂等：文件里已经有 _xxdiy_builtin 就跳过，重复跑多少次都一样；
  * 可逆：将来内核改成 =m 了，把哨兵文件删掉就回到原生判断；
  * 不掩盖真问题：哨兵不在、lsmod 也查不到时，还是照原样报缺组件。

用法:
  tproxy-detect.py <镜像挂载点>            打补丁（幂等）
  tproxy-detect.py --check <镜像挂载点>    只检查，不改文件
"""

from __future__ import annotations

import sys
from pathlib import Path

SENTINEL = "/etc/e5/xxdiy/nft-tproxy-builtin"

OLD = (
    'if (mods:find("REDIRECT") and mods:find("TPROXY")) or '
    '(mods:find("nft_redir") and mods:find("nft_tproxy")) then'
)

NEW = (
    "-- xxdiy: the E5 kernel builds nft_tproxy / nft_redir in (=y), so they never\n"
    "-- show up in lsmod and this check would wrongly report missing components.\n"
    "-- The sentinel is installed by addons/xxdiy; remove it to restore the stock check.\n"
    f'local _xxdiy_builtin = io.open("{SENTINEL}")\n'
    "if _xxdiy_builtin then _xxdiy_builtin:close() end\n"
    'if _xxdiy_builtin or (mods:find("REDIRECT") and mods:find("TPROXY")) or '
    '(mods:find("nft_redir") and mods:find("nft_tproxy")) then'
)

MARKER = "_xxdiy_builtin"

TARGETS = (
    "usr/lib/lua/luci/model/cbi/passwall2/client/global.lua",
    "usr/lib/lua/luci/model/cbi/passwall2/client/other.lua",
)


def context(lines: list[str], needle: str) -> str:
    """找不到原文时，把相近的行打出来，方便判断上游是不是改了写法。"""
    out = []
    for i, line in enumerate(lines, 1):
        if "lsmod" in line or "mods:find" in line or "nft_tproxy" in line or "TPROXY" in line:
            out.append(f"    {i:4d}: {line.rstrip()}")
    if not out:
        out.append("    （连 lsmod / mods:find 都没找到，文件可能不是预期的那份）")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    check_only = False
    args = argv[1:]
    if args and args[0] == "--check":
        check_only = True
        args = args[1:]

    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(args[0])
    if not root.is_dir():
        print(f"挂载点不存在：{root}", file=sys.stderr)
        return 2

    rc = 0
    for rel in TARGETS:
        path = root / rel
        if not path.is_file():
            print(f"  [失败] 找不到 {rel}", file=sys.stderr)
            rc = 1
            continue

        text = path.read_text(encoding="utf-8")

        if MARKER in text:
            print(f"  [已打过] {rel}")
            continue

        if OLD not in text:
            print(f"  [失败] {rel} 里找不到要替换的那一行：", file=sys.stderr)
            print(OLD, file=sys.stderr)
            print("  这个文件里相关的行：", file=sys.stderr)
            print(context(text.splitlines(), OLD), file=sys.stderr)
            print("  （上游可能改了写法，需要更新 addons/xxdiy/plugins/passwall2/patch/tproxy-detect.py）",
                  file=sys.stderr)
            rc = 1
            continue

        if check_only:
            print(f"  [待打补丁] {rel}")
            rc = 1
            continue

        new_text = text.replace(OLD, NEW, 1)
        expect = NEW.count(MARKER)
        if new_text.count(MARKER) != expect:
            print(f"  [失败] {rel} 替换后 _xxdiy_builtin 出现 {new_text.count(MARKER)} 次，应为 {expect}",
                  file=sys.stderr)
            rc = 1
            continue

        # 保留原文件的换行风格：显式 newline="\n"，免得在 Windows 上被改成 CRLF
        with path.open("w", encoding="utf-8", newline="\n") as f:
            f.write(new_text)
        line_no = text[: text.index(OLD)].count("\n") + 1
        print(f"  [已打补丁] {rel}（第 {line_no} 行）")

    if rc == 0 and not check_only:
        print("  tproxy 误判的两处都已处理")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
