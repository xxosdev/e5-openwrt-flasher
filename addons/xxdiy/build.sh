#!/bin/bash
# addons/xxdiy/build.sh —— 把 xxdiy 插件打进刷机包的 ext4，产出新的 openwrt.ext4.gz
#
# 用法:
#   sudo bash addons/xxdiy/build.sh <输入> [输出]
#
#   <输入> 可以是:
#             * 上游刷机包 zip（自动取里面的 <顶层>/files/openwrt.ext4.gz）
#             * 已经解开的 openwrt.ext4.gz
#             * 裸 ext4 镜像
#             * http(s) URL（先下载到 cache/）
#   [输出] 新的 ext4.gz；默认 addons/xxdiy/work/openwrt-<新版本>.ext4.gz
#
# 环境变量:
#   XXDIY_TAG          版本后缀，默认 xxdiy.$(date -u +%Y%m%d)
#   XXDIY_ONLY         只跑这些插件（空格分隔），默认全部
#   XXDIY_SKIP         跳过这些插件（空格分隔）
#   XXDIY_BASE_IMAGE   打 apk 用的 arm64 用户态，默认 e5-openwrt-base:25.12.5
#   XXDIY_CACHE        缓存目录，默认 addons/xxdiy/cache
#   XXDIY_WRT_MIRROR   apk 安装时临时用的源，默认用镜像里原来的官方源
#   XXDIY_MIN_FREE_MB  镜像里至少留多少 MB 空闲，默认 200
#   XXDIY_FSCK_REPAIR  设 1 则对不干净的 ext4 自动 e2fsck -fy
#
# 为什么不用改上游任何文件: 上游 build/make-rootfs-sleepN.sh 的最后一步是
#   gzip -9 -n -c work.ext4 > openwrt-sleepN.ext4.gz
# 我们直接吃它的输出（或者吃已经打好的刷机包），在这一层之上加插件。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() {
    sed -n '2,26p' "$0" | sed -E 's/^# ?//'
    exit "${1:-0}"
}
case "${1:-}" in
    -h|--help) usage 0 ;;
    '')        usage 1 ;;
esac

INPUT=$1
OUTPUT=${2:-}

# 挂载 ext4 必须是 root。不是就自己 sudo 重来一遍。
if [ "$(id -u)" != 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "需要 root 做 loop 挂载，但这台机器没有 sudo"
    log "需要 root，用 sudo 重新执行"
    exec sudo -E bash "$0" "$@"
fi

XXDIY_TAG=${XXDIY_TAG:-xxdiy.$(date -u +%Y%m%d)}
mkdir -p "$XXDIY_CACHE" "$XXDIY_WORK"

IMG=$XXDIY_WORK/base.ext4
GZ=$XXDIY_WORK/base.ext4.gz
MNT=$XXDIY_WORK/mnt

cleanup() {
    if mountpoint -q "$MNT" 2>/dev/null; then
        warn "收尾：卸载 $MNT"
        sync
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 上次跑挂了可能把 mnt 留在挂着，先收拾干净，否则后面的 rm 会 busy
if mountpoint -q "$MNT" 2>/dev/null; then
    warn "$MNT 还挂着（上次没收拾干净），先卸载"
    umount -l "$MNT" 2>/dev/null || true
fi

require_root
ensure_docker

# ---- 1. 取基座 -----------------------------------------------------------
step "1/8 取基座"
src=$INPUT
case "$src" in
    http://*|https://*)
        cached=$XXDIY_CACHE/$(basename "${src%%\?*}")
        if [ ! -s "$cached" ]; then
            log "下载 $src"
            curl -fL --retry 3 --retry-delay 3 --connect-timeout 30 -o "$cached.part" "$src" \
                || die "下载失败：$src"
            mv "$cached.part" "$cached"
        fi
        src=$cached
        ;;
esac
[ -f "$src" ] || die "输入不存在：$src"
log "基座：$src（$(stat -c %s "$src") 字节）"

# ---- 2. 解出 ext4 --------------------------------------------------------
step "2/8 解出 ext4"
rm -f "$IMG" "$GZ"
case "$src" in
    *.zip)
        command -v unzip >/dev/null 2>&1 || die "缺 unzip"
        member=$(unzip -Z1 "$src" | grep -E '(^|/)files/openwrt\.ext4\.gz$' | head -1 || true)
        [ -n "$member" ] || die "zip 里没有 files/openwrt.ext4.gz，不是 E5 刷机包？"
        log "从 zip 取 $member"
        unzip -p "$src" "$member" > "$GZ"
        ;;
    *.gz)
        cp -f "$src" "$GZ"
        ;;
    *)
        cp -f "$src" "$IMG"
        ;;
esac
if [ -f "$GZ" ]; then
    log "解压 ext4.gz（约 2 GB，慢一点）"
    gzip -dc "$GZ" > "$IMG" || die "解压 $GZ 失败"
    rm -f "$GZ"
fi
[ -s "$IMG" ] || die "没得到 ext4 镜像"
log "ext4：$(stat -c %s "$IMG") 字节"

# ---- 3. 检查并挂载 -------------------------------------------------------
step "3/8 检查并挂载"
fsck_img "$IMG"
mount_img "$IMG" "$MNT"
export XXDIY_MNT=$MNT

free=$(free_mb "$MNT")
case "$free" in ''|*[!0-9]*) die "算不出镜像内的空闲空间（df 输出异常：$free）" ;; esac
need=${XXDIY_MIN_FREE_MB:-200}
log "镜像内空闲 ${free} MB（要求至少 ${need} MB）"
[ "$free" -ge "$need" ] \
    || die "镜像内只剩 ${free} MB，不够装插件。上游 e5-linux 的 E5_IMAGE_MB 需要调大后重新出基座"

[ -f "$MNT/etc/e5/image-version" ] || die "镜像里没有 /etc/e5/image-version，不像 E5 刷机包"
BASE_VER=$(tr -d '\r\n' < "$MNT/etc/e5/image-version")
NEW_VER=$(printf '%s' "$BASE_VER" | sed -E 's/-xxdiy\.[0-9]{8}(-[0-9]+)?$//')"-$XXDIY_TAG"
log "基座版本：$BASE_VER"
log "新版本号：$NEW_VER"

ensure_base_image

# ---- 4. 跑插件 -----------------------------------------------------------
step "4/8 跑插件"
shopt -s nullglob
plugins=("$HERE"/plugins/*/install.sh)
shopt -u nullglob
[ ${#plugins[@]} -gt 0 ] || die "addons/xxdiy/plugins/ 下一个插件都没有"

ran=""
for p in "${plugins[@]}"; do
    dir=$(dirname "$p")
    name=$(basename "$dir")
    if [ -n "${XXDIY_ONLY:-}" ] && ! printf '%s\n' $XXDIY_ONLY | grep -qx "$name"; then
        log "跳过 $name（不在 XXDIY_ONLY 里）"
        continue
    fi
    if [ -n "${XXDIY_SKIP:-}" ] && printf '%s\n' $XXDIY_SKIP | grep -qx "$name"; then
        log "跳过 $name（XXDIY_SKIP）"
        continue
    fi
    step "插件：$name"
    XXDIY_PLUGIN_DIR=$dir \
    XXDIY_LIB=$HERE/lib/common.sh \
    XXDIY_MNT=$MNT \
    XXDIY_TAG=$XXDIY_TAG \
    XXDIY_WRT_MIRROR=$XXDIY_WRT_MIRROR \
    bash "$p" "$MNT"
    ran="$ran $name"
done
[ -n "$ran" ] || die "一个插件都没跑（检查 XXDIY_ONLY / XXDIY_SKIP）"

# ---- 5. 写版本标记 -------------------------------------------------------
step "5/8 写版本标记"
mkdir -p "$MNT/etc/e5"
printf '%s\n' "$NEW_VER" > "$MNT/etc/e5/image-version"
printf '%s\n' "$XXDIY_TAG $(date -u +%FT%TZ): $NEW_VER <- $BASE_VER; 插件$ran" \
    > "$MNT/etc/e5/e5-xxdiy.release"
chown 0:0 "$MNT/etc/e5/image-version" "$MNT/etc/e5/e5-xxdiy.release"
chmod 644 "$MNT/etc/e5/image-version" "$MNT/etc/e5/e5-xxdiy.release"
log "image-version: $(tr -d '\n' < "$MNT/etc/e5/image-version")"
log "e5-xxdiy.release: $(tr -d '\n' < "$MNT/etc/e5/e5-xxdiy.release")"

# ---- 6. 卸载 -------------------------------------------------------------
step "6/8 卸载"
umount_img "$MNT"
trap - EXIT

# ---- 7. 重新打包 ---------------------------------------------------------
step "7/8 重新打包"
OUTPUT=${OUTPUT:-$XXDIY_WORK/openwrt-$NEW_VER.ext4.gz}
mkdir -p "$(dirname "$OUTPUT")"
gzip -9 -n -c "$IMG" > "$OUTPUT" || die "gzip 失败"
rm -f "$IMG"
log "输出：$OUTPUT（$(stat -c %s "$OUTPUT") 字节）"
sha256sum "$OUTPUT" | tee "$OUTPUT.sha256"

# ---- 8. 给 rebundle.sh 留一份元信息 --------------------------------------
step "8/8 记录元信息"
INFO=$(dirname "$OUTPUT")/build-info.env
{
    printf 'XXDIY_NEW_VER=%s\n' "$NEW_VER"
    printf 'XXDIY_BASE_VER=%s\n' "$BASE_VER"
    printf 'XXDIY_TAG=%s\n' "$XXDIY_TAG"
    printf 'XXDIY_EXT4_GZ=%s\n' "$OUTPUT"
    printf 'XXDIY_PLUGINS=%s\n' "${ran# }"
} > "$INFO"
log "元信息：$INFO"

printf '\n完成。下一步：\n'
printf '  bash addons/xxdiy/rebundle.sh <上游刷机包.zip> %s <输出.zip> %s\n\n' \
    "$OUTPUT" "$NEW_VER"
