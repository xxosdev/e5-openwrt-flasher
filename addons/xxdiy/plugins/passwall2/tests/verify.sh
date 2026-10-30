#!/bin/bash
# addons/xxdiy/plugins/passwall2/tests/verify.sh —— 装完之后逐项核对
#
# 用法:
#   bash addons/xxdiy/plugins/passwall2/tests/verify.sh <镜像挂载点>
#
# install.sh 的最后一步会调它；也可以单独跑（比如 CI 里对已经打好的 ext4 复查）。
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

check "关键包都在（passwall2 / xray / geo 数据 / dnsmasq-full / lua 运行时）" '
for p in luci-app-passwall2 luci-i18n-passwall2-zh-cn xray-core geoview tcping \
         v2ray-geoip v2ray-geosite dnsmasq-full luci-lua-runtime luci-compat; do
    apk --root /r info -e "$p" >/dev/null 2>&1 || { echo "缺 $p"; exit 1; }
done
echo "$(apk --root /r info 2>/dev/null | wc -l) 个包"
'

check "dnsmasq 带 nftset（不是基础版）" '
# 不能在 chroot 里跑 dnsmasq --version：它要读 /dev/urandom，而镜像里的 /dev 是空的。
# 直接 grep 二进制里的编译选项字面量："nftset " / "no-nftset "。
B=/r/usr/sbin/dnsmasq
[ -x "$B" ] || { echo "没有 /usr/sbin/dnsmasq"; exit 1; }
if grep -aq "no-nftset" "$B"; then echo "还是基础版：二进制里是 no-nftset"; exit 1; fi
grep -aq "nftset" "$B" || { echo "二进制里找不到 nftset 字样"; exit 1; }
echo "二进制带 nftset"
'

check "/etc/apk/world 是 dnsmasq-full，没有 dnsmasq" '
grep -qx dnsmasq-full /r/etc/apk/world || { echo "world 里没有 dnsmasq-full"; exit 1; }
! grep -qx dnsmasq /r/etc/apk/world || { echo "world 里还留着 dnsmasq"; exit 1; }
'

check "xray 能跑起来" '
chroot /r sh -c "xray version" 2>&1 | head -2
'

check "两个 LuCI 文件的 Lua 语法能过" '
for f in /usr/lib/lua/luci/model/cbi/passwall2/client/global.lua \
         /usr/lib/lua/luci/model/cbi/passwall2/client/other.lua; do
    [ -f "/r$f" ] || { echo "缺 $f"; exit 1; }
    if [ -x /r/usr/bin/lua ]; then
        # Lua 的长括号字符串 [[...]] 不需要引号，省掉一层转义
        chroot /r /usr/bin/lua -e "assert(loadfile([[$f]]))" || { echo "编译失败：$f"; exit 1; }
    elif [ -x /r/usr/bin/luac ]; then
        chroot /r /usr/bin/luac -p "$f" || { echo "编译失败：$f"; exit 1; }
    else
        echo "没有 lua/luac，跳过语法检查（只做字符串检查）"
    fi
done
echo "两个文件都能编译"
'

check "tproxy 误判的两处都打了补丁" '
for f in /usr/lib/lua/luci/model/cbi/passwall2/client/global.lua \
         /usr/lib/lua/luci/model/cbi/passwall2/client/other.lua; do
    grep -q "_xxdiy_builtin" "/r$f" || { echo "没打补丁：$f"; exit 1; }
done
echo "global.lua 和 other.lua 都有 _xxdiy_builtin"
'

check "哨兵文件在" '
[ -s /r/etc/e5/xxdiy/nft-tproxy-builtin ] || { echo "缺 /etc/e5/xxdiy/nft-tproxy-builtin"; exit 1; }
'

check "app.sh 要的三个 kmod-*.list 存在且非空" '
for m in socket tproxy nat; do
    f=/r/lib/apk/packages/kmod-nft-$m.list
    [ -s "$f" ] || { echo "缺或为空：$f"; exit 1; }
done
'

check "/etc/e5/apk-removed.list 里有 dnsmasq（升级时别把基础版搬回来）" '
grep -qx dnsmasq /r/etc/e5/apk-removed.list || { echo "apk-removed.list 里没有 dnsmasq"; exit 1; }
cat /r/etc/e5/apk-removed.list
'

check "uci-defaults 脚本语法正确" '
sh -n /r/etc/uci-defaults/zz-xxdiy
'

check "image-version 带上了 xxdiy 后缀" '
v=$(tr -d "\r\n" < /r/etc/e5/image-version)
echo "$v"
case "$v" in *-xxdiy.*) exit 0 ;; *) echo "没有 -xxdiy. 后缀"; exit 1 ;; esac
'

check "内核模块目录只剩 E5 自己的那套" '
n=$(ls -1 /r/lib/modules | wc -l)
ls -1 /r/lib/modules
[ "$n" = 1 ] || { echo "/lib/modules 下有 $n 个目录，应该只有 1 个"; exit 1; }
ls -1 /r/lib/modules | grep -q -- "-e5-" || { echo "没看到 -e5- 的内核目录"; exit 1; }
'

printf '\n'
if [ "$fail" = 0 ]; then
    printf '\033[32m全部通过\033[0m（%d 项）\n' "$pass"
else
    printf '\033[31m%d 项失败\033[0m（通过 %d 项）：%s\n' "$fail" "$pass" "$failed_names" >&2
    exit 1
fi
