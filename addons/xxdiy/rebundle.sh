#!/bin/bash
# addons/xxdiy/rebundle.sh —— 把新的 ext4.gz 塞回上游刷机包，产出新的刷机包 zip
#
# 用法:
#   bash addons/xxdiy/rebundle.sh <上游刷机包.zip> <新 ext4.gz> <输出.zip> [版本号]
#
#   版本号不给的话，先读新 ext4.gz 旁边的 build-info.env（build.sh 写的），
#   再退回从文件名 openwrt-<版本>.ext4.gz 里取。
#
# 设备端 e5-upgrade 对刷机包的硬性要求（见 overlay/*/usr/libexec/e5-upgrade）:
#   * zip 里正好一个顶层目录（Openwrt_E5_Flasher_*），它下面有 files/boot.json
#   * files/ 里必须有 boot.img boot.json openwrt.ext4.gz device-flash-boot.sh
#     device-install-image.sh VERSION
#   * SHA256SUMS 在顶层目录，路径相对顶层目录，用 `cd 顶层 && sha256sum -c` 校验
#
# 本脚本只动三样东西：files/openwrt.ext4.gz、files/VERSION、顶层目录名，
# 外加重算 SHA256SUMS。boot.img / boot.json 一个字节都不碰
# （boot.json 里的 sha256_head56m 是 boot.img 头 56 MB 的哈希，动了就对不上）。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() {
    sed -n '2,18p' "$0" | sed -E 's/^# ?//'
    exit "${1:-0}"
}
case "${1:-}" in
    -h|--help) usage 0 ;;
esac

[ $# -ge 3 ] || usage 1
BASE_ZIP=$1
NEW_EXT4_GZ=$2
OUT_ZIP=$3
VER=${4:-}

[ -s "$BASE_ZIP" ]   || die "上游刷机包不存在或为空：$BASE_ZIP"
[ -s "$NEW_EXT4_GZ" ] || die "新的 ext4.gz 不存在或为空：$NEW_EXT4_GZ"
for c in unzip zip python3 sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "缺 $c"
done

# 输出路径先转成绝对路径：后面要 cd 到临时目录里去打包
OUT_ZIP=$(mkdir -p "$(dirname "$OUT_ZIP")" && cd "$(dirname "$OUT_ZIP")" && printf '%s/%s' "$PWD" "$(basename "$OUT_ZIP")")

TMP=$XXDIY_WORK/rebundle
# build.sh 要 root（loop 挂载），它建出来的 work/ 属于 root；而 rebundle.sh
# 本身不需要 root，普通用户就写不进去。这种情况退到系统临时目录。
if ! mkdir -p "$TMP" 2>/dev/null || [ ! -w "$TMP" ]; then
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/e5-xxdiy-rebundle.XXXXXX") \
        || die "建不了临时目录（$XXDIY_WORK 不可写，mktemp 也失败）"
    warn "$XXDIY_WORK 不可写（build.sh 是 sudo 跑的？），临时目录改用 $TMP"
fi
rm -rf "$TMP" 2>/dev/null || true
mkdir -p "$TMP" || die "建不了临时目录 $TMP"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

# ---- 1. 解包 -------------------------------------------------------------
step "1/6 解包上游刷机包"
unzip -q -o "$BASE_ZIP" -d "$TMP" || die "解包失败：$BASE_ZIP"
log "解到 $TMP"

# ---- 2. 定位顶层目录 -----------------------------------------------------
step "2/6 定位顶层目录"
mapfile -t TOPS < <(
    unzip -Z1 "$BASE_ZIP" \
        | grep -E '^[^/]+/files/boot\.json$' \
        | sed 's#/files/boot\.json$##' \
        | sort -u
)
[ ${#TOPS[@]} -eq 1 ] \
    || die "上游包顶层应该有且只有一个 <顶层>/files/boot.json，实际 ${#TOPS[@]} 个：${TOPS[*]:-无}"
OLD_TOP=${TOPS[0]}
TOPDIR=$TMP/$OLD_TOP
[ -d "$TOPDIR" ] || die "解包后找不到 $OLD_TOP"
log "顶层目录：$OLD_TOP"

# ---- 3. 定版本号 ---------------------------------------------------------
step "3/6 定版本号"
if [ -z "$VER" ]; then
    info=$(dirname "$NEW_EXT4_GZ")/build-info.env
    if [ -f "$info" ]; then
        VER=$(sed -n 's/^XXDIY_NEW_VER=//p' "$info" | head -1)
        [ -n "$VER" ] && log "从 build-info.env 取到版本号"
    fi
fi
if [ -z "$VER" ]; then
    case "$(basename "$NEW_EXT4_GZ")" in
        openwrt-*.ext4.gz) VER=${NEW_EXT4_GZ##*/}; VER=${VER#openwrt-}; VER=${VER%.ext4.gz} ;;
    esac
fi
[ -n "$VER" ] || die "定不出版本号，请作为第 4 个参数传进来"
case "$VER" in
    *[!A-Za-z0-9._+-]*) die "版本号里有奇怪的字符：$VER" ;;
esac
log "版本号：$VER"

# ---- 4. 换 ext4.gz、写 VERSION、改顶层目录名 ------------------------------
step "4/6 换 openwrt.ext4.gz"
for f in boot.img boot.json openwrt.ext4.gz device-flash-boot.sh device-install-image.sh VERSION; do
    [ -s "$TOPDIR/files/$f" ] || die "上游包缺 files/$f，和设备端 e5-upgrade 的要求不符"
done
cp -f "$NEW_EXT4_GZ" "$TOPDIR/files/openwrt.ext4.gz"
log "files/openwrt.ext4.gz：$(stat -c %s "$TOPDIR/files/openwrt.ext4.gz") 字节，sha256 $(sha256sum "$TOPDIR/files/openwrt.ext4.gz" | cut -d' ' -f1)"

# 设备端读它只是显示（tr -d '\n' < files/VERSION），不参与版本比较
printf '%s' "$VER" > "$TOPDIR/files/VERSION"
log "files/VERSION：$VER"

# 顶层目录名照上游习惯来：Openwrt_E5_Flasher_<去掉版本前缀的版本>
# 基座版本可能是 `25.12.5-5ac9d504+e5-sleep14` 或 `5ac9d504+e5-sleep14`
# （sleep14 实际是后者），两种前缀都剥掉。
short=$(printf '%s' "$VER" | sed -E 's/^([0-9.]+-)?[0-9a-f]{7,40}[+]//; s/[^A-Za-z0-9._-]+/_/g')
[ -n "$short" ] || short=$VER
NEW_TOP=${XXDIY_TOPNAME:-Openwrt_E5_Flasher_$short}
if [ "$NEW_TOP" != "$OLD_TOP" ]; then
    [ -e "$TMP/$NEW_TOP" ] && die "$TMP/$NEW_TOP 已存在"
    mv "$TOPDIR" "$TMP/$NEW_TOP"
    TOPDIR=$TMP/$NEW_TOP
    log "顶层目录改名：$OLD_TOP -> $NEW_TOP"
fi

# 执行位：unzip 在 Linux 上一般能还原，但别赌
for f in "$TOPDIR"/*.sh; do
    [ -f "$f" ] && chmod 755 "$f"
done

# ---- 5. 重算 SHA256SUMS --------------------------------------------------
step "5/6 重算 SHA256SUMS"
rm -f "$TOPDIR/SHA256SUMS"
python3 "$HERE/lib/sums.py" "$TOPDIR" || die "重算 SHA256SUMS 失败"

# ---- 6. 打包 -------------------------------------------------------------
step "6/6 打包"
rm -f "$OUT_ZIP"
# -n 让已经压过的东西直接 store，省一遍无用功。
# 只列真正压不动的：.gz（ext4.gz 本身就是 gzip）、.zip、.apk（ADB 容器）。
# ⚠ 千万别把 .img 放进来：boot.img 是 Android boot 镜像，里面有大量填充，
#   压缩率很高。第一版误加了 .img，产物 353 MB（上游才 167 MB），
#   去掉之后降到 200 MB 上下。设备端网页升级要把整个包解到 userdata，
#   这个体积直接关系到能不能装得下。
( cd "$TMP" && zip -q -r -X -n .gz:.zip:.apk:.png:.webp:.jpg:.jpeg "$OUT_ZIP" "$NEW_TOP" ) \
    || die "打包失败"
[ -s "$OUT_ZIP" ] || die "打包后输出为空"

# 自检：设备端要的几个文件在不在、SHA256SUMS 能不能校验过
step "自检"
missing=0
for f in files/boot.img files/boot.json files/openwrt.ext4.gz \
         files/device-flash-boot.sh files/device-install-image.sh files/VERSION SHA256SUMS; do
    if unzip -Z1 "$OUT_ZIP" | grep -qxF "$NEW_TOP/$f"; then
        log "有 $f"
    else
        warn "缺 $f"
        missing=1
    fi
done
[ "$missing" = 0 ] || die "打出来的包缺文件"
# 注意别写成 `sha256sum -c -s`：-s 是 BusyBox 的选项，GNU coreutils 没有，
# CI 上（ubuntu runner）会直接报 unknown option。这里用重定向把 OK 行吞掉。
( cd "$TMP/$NEW_TOP" && sha256sum -c SHA256SUMS >/dev/null ) || die "SHA256SUMS 自校验失败"
log "SHA256SUMS 自校验通过"

printf '\n完成\n'
printf '  刷机包：%s（%s 字节）\n' "$OUT_ZIP" "$(stat -c %s "$OUT_ZIP")"
printf '  版本号：%s\n' "$VER"
sha256sum "$OUT_ZIP"
