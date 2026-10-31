#!/bin/bash
# addons/xxdiy/plugins/filemanager/tests/verify.sh —— 装完之后逐项核对
#
# 用法:
#   bash addons/xxdiy/plugins/filemanager/tests/verify.sh <镜像挂载点>
#
# install.sh 的最后一步会调它；也可以单独跑（比如对已经打好的 ext4 复查）。
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

check "luci-app-filemanager 装上了" '
apk --root /r info -e luci-app-filemanager >/dev/null 2>&1 \
    || { echo "没装 luci-app-filemanager"; exit 1; }
apk --root /r info -v luci-app-filemanager 2>/dev/null | head -2
'

check "中文语言包装上了" '
apk --root /r info -e luci-i18n-filemanager-zh-cn >/dev/null 2>&1 \
    || { echo "没装 luci-i18n-filemanager-zh-cn"; exit 1; }
'

check "JS 视图、菜单、ACL 三个文件都在" '
for f in /r/www/luci-static/resources/view/system/filemanager.js \
         /r/usr/share/luci/menu.d/luci-app-filemanager.json \
         /r/usr/share/rpcd/acl.d/luci-app-filemanager.json; do
    [ -s "$f" ] || { echo "缺或为空：$f"; exit 1; }
done
wc -c /r/www/luci-static/resources/view/system/filemanager.js
'

check "菜单挂在 系统 -> 文件管理器" '
M=/r/usr/share/luci/menu.d/luci-app-filemanager.json
grep -q "admin/system/filemanager" "$M" || { echo "菜单路径不是 admin/system/filemanager"; exit 1; }
grep -q "system/filemanager" "$M" || { echo "视图路径不是 system/filemanager"; exit 1; }
'

# 文件操作全靠 ubus 的 `file` 对象，它由 rpcd-mod-file 提供的 file.so 实现。
# 少了这个，界面能打开，但点任何文件都会报错。
check "rpcd-mod-file 在（file.so 提供文件操作）" '
apk --root /r info -e rpcd-mod-file >/dev/null 2>&1 \
    || { echo "缺 rpcd-mod-file，文件操作会全部失败"; exit 1; }
[ -x /r/usr/lib/rpcd/file.so ] || { echo "缺 /usr/lib/rpcd/file.so"; exit 1; }
ls -l /r/usr/lib/rpcd/file.so
'

check "luci-base 在（依赖）" '
apk --root /r info -e luci-base >/dev/null 2>&1 \
    || { echo "缺 luci-base"; exit 1; }
'

printf '\n'
if [ "$fail" = 0 ]; then
    printf '\033[32m全部通过\033[0m（%d 项）\n' "$pass"
else
    printf '\033[31m%d 项失败\033[0m（通过 %d 项）：%s\n' "$fail" "$pass" "$failed_names" >&2
    exit 1
fi
