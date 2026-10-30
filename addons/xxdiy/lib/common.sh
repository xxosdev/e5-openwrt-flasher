#!/bin/bash
# addons/xxdiy/lib/common.sh
#
# xxdiy 扩展层的公共函数。build.sh、rebundle.sh 和 plugins/*/install.sh 都 source 它。
# 调用方自己负责 `set -euo pipefail`。
#
# 这里刻意不碰上游任何文件：整个扩展层只往镜像里加东西，不修改仓库里已有的脚本，
# 这样 `git fetch upstream` 之后合并永远不会有冲突。

# ---- 路径与基座 ----------------------------------------------------------
XXDIY_ROOT=${XXDIY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
XXDIY_CACHE=${XXDIY_CACHE:-$XXDIY_ROOT/cache}
XXDIY_WORK=${XXDIY_WORK:-$XXDIY_ROOT/work}

# 打进镜像时用的 arm64 用户态。版本号就是上游刷机包用的 OpenWrt 版本。
XXDIY_BASE_IMAGE=${XXDIY_BASE_IMAGE:-e5-openwrt-base:25.12.5}
XXDIY_WRT_VER=${XXDIY_WRT_VER:-${XXDIY_BASE_IMAGE##*:}}

# 装 apk 时临时换的源（装完恢复镜像里原来的源）。留空 = 用官方源。
# 国内手搓可以设 https://mirrors.ustc.edu.cn/openwrt
XXDIY_WRT_MIRROR=${XXDIY_WRT_MIRROR:-}

# 压/解 gzip 用哪个命令：有 pigz 就用 pigz（多核，2 GB 的 ext4 快好几倍），
# 没有就退回 gzip。两者输出都是标准 gzip 流，设备端 busybox 照样能解。
XXDIY_GZIP=${XXDIY_GZIP:-$(command -v pigz 2>/dev/null || command -v gzip 2>/dev/null || echo gzip)}

# ---- 输出 ----------------------------------------------------------------
log()  { printf '\033[36m[xxdiy]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[xxdiy] 警告\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[xxdiy] 失败\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- 环境检查 ------------------------------------------------------------
require_root() {
    [ "$(id -u)" = 0 ] || die "需要 root（loop 挂载 ext4）：用 sudo 跑，或直接以 root 执行"
}

ensure_docker() {
    command -v docker >/dev/null 2>&1 || die "找不到 docker"
    docker info >/dev/null 2>&1 || die "docker 守护进程没起来（或当前用户没有权限）"
}

# 基座镜像不在就现造：docker import 官方 armsr rootfs tarball（和 e5-linux
# openwrt/build-rootfs.sh 第 239 行同一招），几秒钟，不用拉任何 registry 镜像。
ensure_base_image() {
    if docker image inspect "$XXDIY_BASE_IMAGE" >/dev/null 2>&1; then
        log "基座镜像就绪：$XXDIY_BASE_IMAGE"
        return 0
    fi
    local ver=$XXDIY_WRT_VER
    local name="openwrt-$ver-armsr-armv8-rootfs.tar.gz"
    local dl="${XXDIY_WRT_DL:-https://downloads.openwrt.org/releases/$ver/targets/armsr/armv8}"
    local tar=$XXDIY_CACHE/$name
    mkdir -p "$XXDIY_CACHE"
    if [ ! -s "$tar" ]; then
        log "下载 $dl/$name"
        curl -fL --retry 3 --retry-delay 3 --connect-timeout 30 -o "$tar.part" "$dl/$name" \
            || die "下载 $name 失败"
        mv "$tar.part" "$tar"
    fi
    local want have
    want=$(curl -fsSL "$dl/sha256sums" 2>/dev/null \
        | awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }') || true
    have=$(sha256sum "$tar" | cut -d' ' -f1)
    if [ -n "$want" ]; then
        [ "$want" = "$have" ] || die "$name 校验不符（期望 $want，实际 $have）"
        log "$name sha256 校验通过"
    else
        warn "拿不到 $name 的官方 sha256，跳过校验"
    fi
    log "docker import -> $XXDIY_BASE_IMAGE"
    docker import --platform linux/arm64 "$tar" "$XXDIY_BASE_IMAGE" >/dev/null \
        || die "docker import 失败"
}

# ---- ext4 镜像 -----------------------------------------------------------
# 上游刷机包里的 ext4 是干净卸载出来的，这里只做只读检查。
# 真有问题时默认拒绝继续（在脏文件系统上 apk 写入很危险），
# 确认无碍可以 XXDIY_FSCK_REPAIR=1 自动修复。
fsck_img() {
    local img=$1 out
    command -v e2fsck >/dev/null 2>&1 || die "宿主机缺 e2fsck（apt-get install -y e2fsprogs）"
    if out=$(e2fsck -fn "$img" 2>&1); then
        log "e2fsck：文件系统干净"
        return 0
    fi
    warn "e2fsck 报告问题："
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    if [ "${XXDIY_FSCK_REPAIR:-0}" = "1" ]; then
        warn "XXDIY_FSCK_REPAIR=1：尝试修复"
        e2fsck -fy "$img" >/dev/null 2>&1 || true
        e2fsck -fn "$img" >/dev/null 2>&1 || die "修复后仍有错误，基座镜像已损坏"
        log "已修复"
        return 0
    fi
    die "基座 ext4 不干净。确认无碍可加 XXDIY_FSCK_REPAIR=1 自动修复"
}

mount_img() {
    local img=$1 mnt=$2
    mkdir -p "$mnt"
    mountpoint -q "$mnt" && die "$mnt 已经挂载了，先手工 umount"
    mount -o loop "$img" "$mnt" || die "挂载失败：$img"
    log "已挂载 $mnt"
}

umount_img() {
    local mnt=$1
    mountpoint -q "$mnt" || return 0
    sync
    # 把删掉文件占的块真正丢掉并清零，否则 gzip 会把那些数据一起压进去
    fstrim -v "$mnt" 2>/dev/null || warn "fstrim 不可用（只影响压缩率，不影响结果）"
    umount "$mnt" 2>/dev/null || { warn "umount 失败，改用 lazy"; umount -l "$mnt" || die "卸载 $mnt 失败"; }
    log "已卸载 $mnt"
}

free_mb() { df -Pm "$1" | awk 'NR == 2 { print $4 }'; }

# ---- 在 arm64 用户态里跑命令 ---------------------------------------------
# run_in_root '<shell 脚本>' [额外的 docker 参数...]
#   容器里：/r = 镜像挂载点，/cache = XXDIY_CACHE（只读）
run_in_root() {
    local script=$1; shift
    docker run --rm --platform linux/arm64 \
        -v "$XXDIY_MNT:/r" \
        -v "$XXDIY_CACHE:/cache:ro" \
        "$@" \
        "$XXDIY_BASE_IMAGE" sh -euc "$script"
}
