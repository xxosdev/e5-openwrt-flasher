#!/bin/bash
# addons/xxdiy/plugins/filemanager/install.sh —— 装 LuCI 文件管理器
#
# 插件契约：install.sh <镜像挂载点>
#   build.sh 会设置 XXDIY_LIB / XXDIY_PLUGIN_DIR / XXDIY_MNT / XXDIY_TAG
#   必须幂等：在已经装好的镜像上再跑一遍，结果要一样。
#
# 这个插件比 passwall2 简单得多。luci-app-filemanager 在**官方 25.12.5 源里就有**
# （openwrt/luci 的 applications/luci-app-filemanager），所以：
#   * 不用下载 apk、不用校验 sha256（源就是官方源）
#   * 不用打补丁、不用改 uci 配置、不用 overlay
#   * 一条 apk add 就完事
#
#   luci-app-filemanager          装完 88 KiB，依赖只有 libc + luci-base
#   luci-i18n-filemanager-zh-cn   简体中文
#
# 它是纯 JS 的 LuCI 应用（htdocs/ + menu.d + acl.d），文件操作走 ubus 的 `file`
# 对象 —— 也就是 rpcd-mod-file 提供的 /usr/lib/rpcd/file.so，镜像里本来就装了。
# 所以没有任何额外的运行时依赖。
#
# 菜单出现在「系统 → 文件管理器」（menu.d 里是 admin/system/filemanager）。
set -euo pipefail

MNT=${1:?用法: install.sh <镜像挂载点>}
. "${XXDIY_LIB:?build.sh 没有设置 XXDIY_LIB}"
PLUGIN_DIR=${XXDIY_PLUGIN_DIR:?build.sh 没有设置 XXDIY_PLUGIN_DIR}
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"
ensure_docker

# 版本交给 apk 从官方源自己解析，不钉死。
#
# 曾经钉死过 26.303.28702~0229375，理由是「25.12.5 是已发布版本，feed 冻结」。
# 这个前提是错的：上游每次换基线（e5-sleep16）都会重新生成 feed，LuCI 的包跟着
# 往前走（filemanager 已到 26.304.26398~e969939），apk 遇到「请求版本 != 源里版本」
# 直接判定不可满足，整个构建挂掉。不钉版本就没这个问题。
#
# filemanager 是纯 JS 应用（htdocs/ + menu.d + acl.d），版本号只是 LuCI 的日期式
# 版本（26.304 = 2026 年第 304 天），升级不涉及接口变化，所以随便装哪个版本都行。
#
# 确实需要复现某个具体版本时才覆盖：
#   XXDIY_FILEMANAGER_VER=xxx bash addons/xxdiy/build.sh ...
VER=${XXDIY_FILEMANAGER_VER:-}
if [ -n "$VER" ]; then
    PKGS="luci-app-filemanager=$VER luci-i18n-filemanager-zh-cn=$VER"
else
    PKGS="luci-app-filemanager luci-i18n-filemanager-zh-cn"
fi

have_pkg() {
    run_in_root "apk --root /r info -e $1 >/dev/null 2>&1" >/dev/null 2>&1
}

# ---- 1. 装 ---------------------------------------------------------------
step "1/2 装 luci-app-filemanager ${VER:-(源里最新)}"
if have_pkg luci-app-filemanager; then
    log "已经装过了，跳过"
else
    # 单引号包住：这段是在容器里跑的，$ 都要留给容器展开
    run_in_root '
set -e
MIRROR="${XXDIY_WRT_MIRROR:-}"
F=/r/etc/apk/repositories.d/distfeeds.list
if [ -n "$MIRROR" ] && [ -f "$F" ]; then
    cp "$F" /tmp/distfeeds.official
    sed -i "s#https://downloads.openwrt.org#$MIRROR#" "$F"
    echo "临时换源：$MIRROR"
fi
restore() {
    if [ -n "$MIRROR" ] && [ -f /tmp/distfeeds.official ]; then
        cp /tmp/distfeeds.official "$F"
        echo "源已恢复成官方"
    fi
}
if ! apk --root /r add $XXDIY_FM_PKGS; then
    restore
    echo "!! 装不上。先看源里现在有哪些版本："
    apk --root /r search -v luci-app-filemanager 2>&1 | head -3 || true
    echo "   （未钉版本时还装不上，通常是官方源不可达或 luci-base 依赖冲突）"
    exit 1
fi
restore
echo "--- 装完的样子 ---"
apk --root /r info -v luci-app-filemanager 2>/dev/null | head -2
' -e "XXDIY_WRT_MIRROR=${XXDIY_WRT_MIRROR:-}" -e "XXDIY_FM_PKGS=$PKGS"
fi

# ---- 2. 自检 -------------------------------------------------------------
step "2/2 自检"
bash "$PLUGIN_DIR/tests/verify.sh" "$MNT"

log "filemanager 插件完成"
