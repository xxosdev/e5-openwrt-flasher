#!/bin/bash
# addons/xxdiy/plugins/ddns-go/tests/verify.sh —— 装完之后逐项核对
#
# 用法:
#   bash addons/xxdiy/plugins/ddns-go/tests/verify.sh <镜像挂载点>
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

check "ddns-go 二进制在且可执行" '
[ -x /r/usr/bin/ddns-go ] || { echo "缺 /r/usr/bin/ddns-go"; ls -l /r/usr/bin/ | grep -i ddns; exit 1; }
ls -l /r/usr/bin/ddns-go
'

check "init 脚本在" '
[ -x /r/etc/init.d/ddns-go ] || { echo "缺 /r/etc/init.d/ddns-go"; exit 1; }
'

check "LuCI 界面文件齐" '
for f in /r/www/luci-static/resources/view/ddns-go/config.js \
         /r/usr/share/luci/menu.d/luci-app-ddns-go.json \
         /r/usr/share/rpcd/acl.d/luci-app-ddns-go.json; do
    [ -s "$f" ] || { echo "缺或为空：$f"; exit 1; }
done
ls /r/www/luci-static/resources/view/ddns-go/
'

check "rpcd 的 ucode 插件在（界面靠它调后端）" '
[ -s /r/usr/share/rpcd/ucode/luci.ddns-go ] || { echo "缺 luci.ddns-go"; exit 1; }
[ -x /r/usr/libexec/ddns-go-call ] || { echo "缺 ddns-go-call 或没有可执行位"; exit 1; }
'

check "默认不开机自启（/etc/rc.d 里没有 ddns-go）" '
n=$(ls /r/etc/rc.d/ 2>/dev/null | grep -c "ddns-go" || true)
[ "${n:-0}" = 0 ] || { echo "/etc/rc.d 里还有 $n 个 ddns-go 链接："; ls /r/etc/rc.d/ | grep ddns-go; exit 1; }
echo "干净"
'

check "关自启的 uci-defaults 在" '
[ -x /r/etc/uci-defaults/zz-xxdiy-ddns-go-off ] || { echo "缺 zz-xxdiy-ddns-go-off"; exit 1; }
'

printf '\n'
if [ "$fail" = 0 ]; then
    printf '\033[32m全部通过\033[0m（%d 项）\n' "$pass"
else
    printf '\033[31m%d 项失败\033[0m（通过 %d 项）：%s\n' "$fail" "$pass" "$failed_names" >&2
    exit 1
fi
