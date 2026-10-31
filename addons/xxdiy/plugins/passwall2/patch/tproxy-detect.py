#!/usr/bin/env python3
"""修 passwall2 对「透明代理组件」的误判。

E5 的内核（6.18.54-e5-sleep14-charles）把 nft_tproxy / nft_socket / nft_redir
都编进了内核（=y），所以 `lsmod` 里永远看不到它们。passwall2 靠 lsmod 判断，
于是认为「缺组件」。全仓一共 3 处（都在 LuCI 里，iptables.sh 那 2 处只在
iptables 后端生效，我们用 nftables，走不到）：

  client/global.lua
    1. 组件总开关   -> Localhost Proxy / Client Proxy 变成灰色禁用的复选框，
                       外加一行红字 "Missing components, transparent proxy is unavailable."

  client/other.lua
    2. 组件总开关   -> 整个「TCP Proxy Way」下拉框直接消失，连 REDIRECT/TPROXY 都没得选
                      （和 global.lua 里是同一行代码）
    3. IPv6 开关    -> 嵌在上面那个 if 里面，判断的是
                      `ip6table_mangle` 或 `nft_tproxy`，两者在 lsmod 里都没有，
                      于是「IPv6 TProxy」复选框根本不出现

做法是插一个哨兵文件判断，而不是写死 true：

    local _xxdiy_builtin = io.open("/etc/e5/xxdiy/nft-tproxy-builtin")
    if _xxdiy_builtin then _xxdiy_builtin:close() end
    if _xxdiy_builtin or (mods:find(...) ...) then

这样：
  * 幂等：每一处都按自己的补丁后特征判断，重复跑多少次都一样；
          老版本脚本只打了第 1、2 处，新脚本会补上第 3 处，不会整份跳过；
  * 可逆：将来内核改成 =m 了，把哨兵文件删掉就回到原生判断；
  * 不掩盖真问题：哨兵不在、lsmod 也查不到时，还是照原样报缺组件。

第 3 处用的 `_xxdiy_builtin` 是第 1 处那个 local，作用域是整个 chunk，
所以在 other.lua 里可以直接引用；万一第 1 处没打上，Lua 读未定义变量得 nil，
会退回原生判断，不会报错。

用法:
  tproxy-detect.py <镜像挂载点>            打补丁（幂等）
  tproxy-detect.py --check <镜像挂载点>    只检查，不改文件
"""

from __future__ import annotations

import sys
from pathlib import Path

SENTINEL = "/etc/e5/xxdiy/nft-tproxy-builtin"

CLIENT_DIR = "usr/lib/lua/luci/model/cbi/passwall2/client/"

# ---- 第 1、2 处：组件总开关（两个文件里是同一行）--------------------------
OLD_COMPONENTS = (
    'if (mods:find("REDIRECT") and mods:find("TPROXY")) or '
    '(mods:find("nft_redir") and mods:find("nft_tproxy")) then'
)

NEW_COMPONENTS = (
    "-- xxdiy: the E5 kernel builds nft_tproxy / nft_redir in (=y), so they never\n"
    "-- show up in lsmod and this check would wrongly report missing components.\n"
    "-- The sentinel is installed by addons/xxdiy; remove it to restore the stock check.\n"
    f'local _xxdiy_builtin = io.open("{SENTINEL}")\n'
    "if _xxdiy_builtin then _xxdiy_builtin:close() end\n"
    'if _xxdiy_builtin or (mods:find("REDIRECT") and mods:find("TPROXY")) or '
    '(mods:find("nft_redir") and mods:find("nft_tproxy")) then'
)

# 补丁后的特征片段。比整段 NEW 短，这样将来只改注释措辞也不会被误判成"没打过"。
MARK_COMPONENTS = '_xxdiy_builtin or (mods:find("REDIRECT")'

# ---- 第 3 处：IPv6 TProxy 开关（只在 other.lua）---------------------------
OLD_IPV6 = 'if mods:find("ip6table_mangle") or mods:find("nft_tproxy") then'

NEW_IPV6 = (
    'if _xxdiy_builtin or mods:find("ip6table_mangle") or mods:find("nft_tproxy") then'
)

MARK_IPV6 = '_xxdiy_builtin or mods:find("ip6table_mangle")'

# rel -> [(原文, 替换成, 补丁后特征, 人话标签), ...]
PATCHES: dict[str, list[tuple[str, str, str, str]]] = {
    CLIENT_DIR + "global.lua": [
        (OLD_COMPONENTS, NEW_COMPONENTS, MARK_COMPONENTS, "组件总开关"),
    ],
    CLIENT_DIR + "other.lua": [
        (OLD_COMPONENTS, NEW_COMPONENTS, MARK_COMPONENTS, "组件总开关"),
        (OLD_IPV6, NEW_IPV6, MARK_IPV6, "IPv6 TProxy 开关"),
    ],
}


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
    total = sum(len(v) for v in PATCHES.values())
    done = 0

    for rel, patches in PATCHES.items():
        path = root / rel
        if not path.is_file():
            print(f"  [失败] 找不到 {rel}", file=sys.stderr)
            rc = 1
            continue

        original = path.read_text(encoding="utf-8")
        text = original

        for old, new, marker, label in patches:
            where = f"{Path(rel).name} · {label}"

            if marker in text:
                print(f"  [已打过] {where}")
                done += 1
                continue

            if old not in text:
                print(f"  [失败] {where}：文件里找不到要替换的那一行", file=sys.stderr)
                print("  期待原文：", file=sys.stderr)
                print(f"    {old}", file=sys.stderr)
                print("  这个文件里相关的行：", file=sys.stderr)
                print(context(text.splitlines(), old), file=sys.stderr)
                print("  （上游可能改了写法，需要更新 "
                      "addons/xxdiy/plugins/passwall2/patch/tproxy-detect.py）",
                      file=sys.stderr)
                rc = 1
                continue

            if check_only:
                print(f"  [待打补丁] {where}")
                rc = 1
                continue

            # 行号按打补丁之前的位置算，方便和上游源码对照
            line_no = original[: original.index(old)].count("\n") + 1

            text = text.replace(old, new, 1)
            if old in text:
                print(f"  [失败] {where}：替换后原文仍然存在，没换掉", file=sys.stderr)
                rc = 1
                continue

            print(f"  [已打补丁] {where}（第 {line_no} 行）")
            done += 1

        if text != original and not check_only:
            # 显式 newline="\n"：免得在 Windows 上被改写成 CRLF
            with path.open("w", encoding="utf-8", newline="\n") as f:
                f.write(text)

    if rc == 0 and not check_only:
        print(f"  tproxy 误判的 {total} 处都已处理（{done}/{total}）")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
