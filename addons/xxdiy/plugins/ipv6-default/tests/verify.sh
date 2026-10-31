#!/bin/bash
# addons/xxdiy/plugins/ipv6-default/tests/verify.sh —— 装完之后逐项核对
#
# 用法:
#   bash addons/xxdiy/plugins/ipv6-default/tests/verify.sh <镜像挂载点>
#
# 这个插件只放一个文件，所以直接在宿主机上查，不用起 docker。
set -euo pipefail

MNT=${1:?用法: verify.sh <镜像挂载点>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../../lib/common.sh
. "$HERE/../../../lib/common.sh"
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"

F=$MNT/etc/uci-defaults/90-xxdiy-ipv6

pass=0
fail=0
failed_names=""

check() { # <描述> <命令>
    local desc=$1 cmd=$2
    # 一定要放进子 shell：检查脚本里会写 `{ echo ...; exit 1; }`，
    # 在当前 shell 里 eval 的话那个 exit 会把整个 verify.sh 干掉，
    # 结果就是「5 个 ✓ 之后无声退出 1」，连失败项都不打印。
    if ( eval "$cmd" ) >/dev/null 2>&1; then
        printf '  \033[32m✓\033[0m %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$desc"
        fail=$((fail + 1))
        failed_names="$failed_names
    - $desc"
        ( eval "$cmd" ) 2>&1 | sed 's/^/      /' || true
    fi
}

check "uci-defaults 脚本在且可执行" "[ -x '$F' ] && echo '$F'"

check "shell 语法能过" "bash -n '$F'"

check "写的是 enabled=0（不是 1）" "
grep -qF 'uci set \"\$CFG.settings.enabled=0\"' '$F' || { echo '没找到 enabled=0'; exit 1; }
! grep -qF 'settings.enabled=1' '$F' || { echo '居然还有 enabled=1'; exit 1; }
"

# 关键：只在「还没设过」时才写，否则会把用户自己的选择冲掉
check "只在没设过时才写（不会覆盖用户选择）" "
grep -qF 'uci -q get \"\$CFG.settings.enabled\"' '$F' || { echo '没有读取现有值的判断'; exit 1; }
grep -qF '[ -z ' '$F' || { echo '没有空值判断'; exit 1; }
"

check "结尾 exit 0（否则 uci-defaults 不会被删，每次开机都跑）" "
tail -1 '$F' | grep -qx 'exit 0' || { tail -3 '$F'; exit 1; }
"

check "不碰 wan_ipv4 / filter_aaaa（只看非注释行）" "
# 注意：这个文件的注释里正好写了『不动 wan_ipv4 / filter_aaaa』，
# 直接全文 grep 会被自己的注释命中。先剥掉注释再查。
if sed 's/#.*//' '$F' | grep -qF 'wan_ipv4'; then echo '不该动 wan_ipv4'; exit 1; fi
if sed 's/#.*//' '$F' | grep -qF 'filter_aaaa'; then echo '不该动 filter_aaaa'; exit 1; fi
"

printf '\n'
if [ "$fail" = 0 ]; then
    printf '\033[32m全部通过\033[0m（%d 项）\n' "$pass"
else
    printf '\033[31m%d 项失败\033[0m（通过 %d 项）：%s\n' "$fail" "$pass" "$failed_names" >&2
    exit 1
fi
