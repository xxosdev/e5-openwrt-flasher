#!/bin/bash
# addons/xxdiy/plugins/ipv6-default/install.sh —— 让「禁用 IPv6」默认是关
#
# 插件契约：install.sh <镜像挂载点>
#   build.sh 会设置 XXDIY_LIB / XXDIY_PLUGIN_DIR / XXDIY_MNT / XXDIY_TAG
#   必须幂等：在已经装好的镜像上再跑一遍，结果要一样。
#
# 这个插件只做一件事：往镜像里放一个 uci-defaults 脚本，首次开机把
# e5-plugin-noipv6.settings.enabled 显式写成 0，这样信息屏「设置 → 网络」
# 里的「禁用 IPv6」默认就是关，IPv6 开箱可用。
#
# 不碰任何上游文件 —— 原因写在 overlay/etc/uci-defaults/90-xxdiy-ipv6 的头部注释里。
set -euo pipefail

MNT=${1:?用法: install.sh <镜像挂载点>}
. "${XXDIY_LIB:?build.sh 没有设置 XXDIY_LIB}"
PLUGIN_DIR=${XXDIY_PLUGIN_DIR:?build.sh 没有设置 XXDIY_PLUGIN_DIR}
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"

step "1/2 放 uci-defaults（禁用 IPv6 默认关）"
cp -a "$PLUGIN_DIR/overlay/." "$MNT/"
F="$MNT/etc/uci-defaults/90-xxdiy-ipv6"
chown 0:0 "$F"
chmod 755 "$F"
log "uci-defaults：$F"

step "2/2 自检"
bash "$PLUGIN_DIR/tests/verify.sh" "$MNT"

log "ipv6-default 插件完成"
