#!/usr/bin/env python3
"""把 passwall2 的「远程 DNS 查询策略」默认值从 UseIPv4 改成 UseIP。

direct_dns_query_strategy 本来就都是 UseIP，不用动。remote 这个值写在四处：

  1. etc/config/passwall2
         option remote_dns_query_strategy 'UseIPv4'
     **这是真正生效的那个。** 包直接把配置文件发下来了，开机就有，不会从
     0_default_config 生成 —— 只改 0_default_config 是改不到的，真机上就是
     栽在这里（镜像里 0_default_config 已经是 UseIP，uci 里还是 UseIPv4）。

  2. usr/share/passwall2/0_default_config
         option remote_dns_query_strategy 'UseIPv4'
     配置文件被删掉/重置时用它重建，也得改。

  3. usr/lib/lua/luci/model/cbi/passwall2/client/global.lua
         o = s:taboption("DNS", ListValue, "remote_dns_query_strategy", ...)
         o.default = "UseIPv4"
     界面上的默认值，uci 里没有这一项时才用得上。

  4. usr/share/passwall2/app_acl.lua
         remote_dns_query_strategy = uci_get("@global[0]", "remote_dns_query_strategy") or "UseIPv4",
     ACL 读不到配置时的兜底。

为什么必须改：UseIPv4 只向远程 DNS 要 A 记录，UseIP 同时要 A 和 AAAA。
在双栈网络上用 UseIPv4，IPv6 目标站点会解析不到地址。

用法:
  dns-query-strategy.py <镜像挂载点>            打补丁（幂等）
  dns-query-strategy.py --check <镜像挂载点>    只检查，不改文件
"""

from __future__ import annotations

import sys
from pathlib import Path

# 注意：global.lua 里 "UseIPv4" 还作为下拉选项出现在 o:value("UseIPv4")，
# 所以第 2 处必须连同上一行的 taboption 一起匹配，不能只换 o.default 那一行。
OLD_LUA = (
    'o = s:taboption("DNS", ListValue, "remote_dns_query_strategy", '
    'translate("Remote Query Strategy"))\n'
    'o.default = "UseIPv4"'
)
NEW_LUA = (
    'o = s:taboption("DNS", ListValue, "remote_dns_query_strategy", '
    'translate("Remote Query Strategy"))\n'
    'o.default = "UseIP"'
)

OLD_ACL = (
    'remote_dns_query_strategy = uci_get("@global[0]", "remote_dns_query_strategy") '
    'or "UseIPv4",'
)
NEW_ACL = (
    'remote_dns_query_strategy = uci_get("@global[0]", "remote_dns_query_strategy") '
    'or "UseIP",'
)

OLD_DEF = "option remote_dns_query_strategy 'UseIPv4'"
NEW_DEF = "option remote_dns_query_strategy 'UseIP'"

# rel -> [(原文, 替换成, 补丁后特征, 人话标签), ...]
PATCHES: dict[str, list[tuple[str, str, str, str]]] = {
    "etc/config/passwall2": [
        (OLD_DEF, NEW_DEF, NEW_DEF, "实际配置"),
    ],
    "usr/share/passwall2/0_default_config": [
        (OLD_DEF, NEW_DEF, NEW_DEF, "uci 默认值"),
    ],
    "usr/lib/lua/luci/model/cbi/passwall2/client/global.lua": [
        (OLD_LUA, NEW_LUA, NEW_LUA, "界面默认值"),
    ],
    "usr/share/passwall2/app_acl.lua": [
        (OLD_ACL, NEW_ACL, NEW_ACL, "ACL 兜底"),
    ],
}

# 这几版是随包发的配置文件，不是每个版本都有。没有就跳过，不要因此让整个构建失败
# （缺了它顶多是首次开机从 0_default_config 生成，那条路我们也改了）。
OPTIONAL = {"etc/config/passwall2"}


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
            if rel in OPTIONAL:
                print(f"  [跳过] 没有 {rel}（这一版不随包发，首次开会从默认配置生成）")
                continue
            print(f"  [失败] 找不到 {rel}", file=sys.stderr)
            rc = 1
            continue

        original = path.read_text(encoding="utf-8")
        text = original

        for old, new, marker, label in patches:
            where = f"{Path(rel).name} · {label}"

            if marker in text:
                print(f"  [已改过] {where}")
                done += 1
                continue

            if old not in text:
                print(f"  [失败] {where}：找不到要替换的原文", file=sys.stderr)
                print(f"    期待：{old!r}", file=sys.stderr)
                print("  （上游可能改了写法，需要更新 "
                      "addons/xxdiy/plugins/passwall2/patch/dns-query-strategy.py）",
                      file=sys.stderr)
                rc = 1
                continue

            if check_only:
                print(f"  [待改] {where}")
                rc = 1
                continue

            line_no = original[: original.index(old)].count("\n") + 1
            text = text.replace(old, new, 1)
            if old in text:
                print(f"  [失败] {where}：替换后原文仍在", file=sys.stderr)
                rc = 1
                continue
            print(f"  [已改] {where}（第 {line_no} 行）")
            done += 1

        if text != original and not check_only:
            with path.open("w", encoding="utf-8", newline="\n") as f:
                f.write(text)

    if rc == 0 and not check_only:
        print(f"  DNS 查询策略默认值已全部改为 UseIP（{done}/{total}）")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
