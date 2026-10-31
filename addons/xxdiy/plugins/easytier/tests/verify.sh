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

check "默认不启动：配置里 enabled / web_enabled 都是 0" '
# 这才是「装了不跑核心」的真正保证。init 脚本 start_service() 里是
#   [ "$(uci -q get easytier.@easytier[0].enabled)" = "1" ] && start_et easytier
# 两个值都是 0 时它空跑一遍就返回。
# 注意：首次开机上游 uci-defaults 会 /etc/init.d/easytier enable 建出
# /etc/rc.d/S99easytier，那是上游设计，不用去删 —— 核心照样不会起来。
C=/r/etc/config/easytier
[ -s "$C" ] || { echo "缺 $C"; exit 1; }
e=$(awk "/^[[:space:]]*config[[:space:]]+easytier/ {f=1; next} f && /^[[:space:]]*config/ {f=0} f && /enabled/ {print}" "$C")
echo "$e"
# 值写成 '0' 还是 0 都接受：用 [^0-9]* 吞掉引号，别在单引号串里塞单引号
echo "$e" | grep -qE "^[[:space:]]*option[[:space:]]+enabled[[:space:]]+[^0-9]*0[^0-9]*$" \
    || { echo "enabled 默认不是 0，开机会拉起核心"; exit 1; }
echo "$e" | grep -qE "^[[:space:]]*option[[:space:]]+web_enabled[[:space:]]+[^0-9]*0[^0-9]*$" \
    || { echo "web_enabled 默认不是 0，开机会拉起 easytier-web"; exit 1; }
echo "两个都是 0"
'

check "init 脚本里确实按 enabled 判断才启动" '
# 防止上游哪天改了判断逻辑，导致上面的默认值不再起作用
grep -q "easytier\[0\]\.enabled" /r/etc/init.d/easytier \
    || { echo "init 脚本里找不到 enabled 判断，行为可能变了"; exit 1; }
grep -n "start_et" /r/etc/init.d/easytier | head -3
'

printf '\n'
if [ "$fail" = 0 ]; then
    printf '\033[32m全部通过\033[0m（%d 项）\n' "$pass"
else
    printf '\033[31m%d 项失败\033[0m（通过 %d 项）：%s\n' "$fail" "$pass" "$failed_names" >&2
    exit 1
fi
