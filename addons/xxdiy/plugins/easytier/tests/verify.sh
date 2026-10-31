#!/bin/bash
# addons/xxdiy/plugins/easytier/tests/verify.sh —— 装完之后逐项核对
#
# 用法:
#   bash addons/xxdiy/plugins/easytier/tests/verify.sh <镜像挂载点>
#
# 成功时安静，失败时把容器里的输出原样贴出来。
set -euo pipefail

MNT=${1:?用法: verify.sh <镜像挂载点>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../../lib/common.sh
. "$HERE/../../../lib/common.sh"
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"
ensure_docker

pass=0
fail=0
failed_names=""

check() { # <描述> <容器内脚本>
    local desc=$1 script=$2
    if run_in_root "$script" >/dev/null 2>&1; then
        printf '  \033[32m✓\033[0m %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s\n' "$desc"
        fail=$((fail + 1))
        failed_names="$failed_names
    - $desc"
        run_in_root "$script" 2>&1 | sed 's/^/      /' || true
    fi
}

check "easytier 二进制在且可执行" '
B=/r/usr/bin/easytier
[ -x "$B" ] || B=/r/usr/sbin/easytier
[ -x "$B" ] || { echo "没找到 easytier 可执行文件"; ls -l /r/usr/bin/ | grep -i easy; exit 1; }
ls -l "$B"
'

check "init 脚本在且可执行" '
[ -x /r/etc/init.d/easytier ] || { echo "缺或不可执行：/r/etc/init.d/easytier"; exit 1; }
'

check "LuCI 的 Lua 文件齐（CBI + 视图 + 控制器）" '
for f in /r/usr/lib/lua/luci/controller/easytier.lua \
         /r/usr/lib/lua/luci/model/cbi/easytier.lua \
         /r/usr/lib/lua/luci/view/easytier/easytier_status.htm; do
    [ -s "$f" ] || { echo "缺或为空：$f"; exit 1; }
done
ls /r/usr/lib/lua/luci/view/easytier/
'

check "配置文件在" '
[ -s /r/etc/config/easytier ] || { echo "缺 /r/etc/config/easytier"; exit 1; }
[ -s /r/etc/easytier/config.toml ] || { echo "缺 /r/etc/easytier/config.toml"; exit 1; }
'

check "Lua CBI 的运行时要装（luci-compat / luci-lua-runtime）" '
for p in luci-compat luci-lua-runtime; do
    apk --root /r info -e "$p" >/dev/null 2>&1 || { echo "缺 $p，页面会白屏"; exit 1; }
done
echo "两个都在"
'

check "TUN 能力在（内核内建，不需要 kmod-tun 包）" '
[ -c /r/dev/net/tun ] || { echo "缺 /r/dev/net/tun"; exit 1; }
ls -l /r/dev/net/tun
'

check "默认不开机自启（/etc/rc.d 里没有 easytier）" '
n=$(ls /r/etc/rc.d/ 2>/dev/null | grep -c "easytier" || true)
[ "${n:-0}" = 0 ] || { echo "/etc/rc.d 里还有 $n 个 easytier 链接："; ls /r/etc/rc.d/ | grep easytier; exit 1; }
echo "干净"
'

check "关自启的 uci-defaults 排在 luci-easytier 之后" '
F=/r/etc/uci-defaults/zz-xxdiy-easytier-off
[ -x "$F" ] || { echo "缺 $F"; exit 1; }
# 字典序：zz- 必须排在 luci-easytier 后面，否则关不掉上游的 enable
printf "luci-easytier\nzz-xxdiy-easytier-off\n" | sort -c 2>/dev/null \
    || { echo "排序不对：zz- 没排在 luci-easytier 之后"; exit 1; }
echo "顺序正确"
'

printf '\n'
if [ "$fail" = 0 ]; then
    printf '\033[32m全部通过\033[0m（%d 项）\n' "$pass"
else
    printf '\033[31m%d 项失败\033[0m（通过 %d 项）：%s\n' "$fail" "$pass" "$failed_names" >&2
    exit 1
fi
