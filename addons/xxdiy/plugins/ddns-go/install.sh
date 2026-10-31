#!/bin/bash
# addons/xxdiy/plugins/ddns-go/install.sh —— 把 ddns-go 和它的 LuCI 界面装进镜像
#
# 插件契约：install.sh <镜像挂载点>
#   build.sh 会设置 XXDIY_LIB / XXDIY_PLUGIN_DIR / XXDIY_MNT / XXDIY_TAG
#   必须幂等：在已经装好的镜像上再跑一遍，结果要一样。
#
# ddns-go 不在官方 25.12.5 源里，只有 GitHub Release 上的 ipk。所以这里不走
# apk，而是把 ipk 解出 data.tar 直接铺进 ext4 —— 和 overlay 是一个思路，
# 只是内容来自上游打的包。好处是绕开 apk 的依赖解析、签名和 postinst，
# 也顺带让服务不会因为 postinst 而自动开机自启。
#
# 铺完之后**默认不开机自启**（用户要求）：
#   * 构建时：删掉 /etc/rc.d 里可能存在的 S/K 链接
#   * 开机时：overlay 里的 zz-xxdiy-ddns-go-off 再 disable + stop 一次
#     （ddns-go 自己的 99-luci-ddns-go 不会 enable，但多一道保险不亏）
set -euo pipefail

MNT=${1:?用法: install.sh <镜像挂载点>}
. "${XXDIY_LIB:?build.sh 没有设置 XXDIY_LIB}"
PLUGIN_DIR=${XXDIY_PLUGIN_DIR:?build.sh 没有设置 XXDIY_PLUGIN_DIR}
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"
ensure_docker

SVC=ddns-go
CACHE=$XXDIY_CACHE/$SVC

# ---- 1. 准备 -------------------------------------------------------------
step "1/5 下载并解出 ipk"
bash "$PLUGIN_DIR/fetch.sh"

# ---- 2. 铺文件 -----------------------------------------------------------
step "2/5 铺文件进镜像"
shopt -s nullglob
pkgs=("$CACHE"/*.data.tar)
shopt -u nullglob
[ ${#pkgs[@]} -gt 0 ] || die "$CACHE 里没有 data.tar，fetch.sh 没跑成功？"

for t in "${pkgs[@]}"; do
    # -p 保留权限位；--numeric-owner 不按用户名查（镜像里没有这些用户）
    tar -xpf "$t" -C "$MNT" --numeric-owner || die "铺失败：$t"
    log "铺了 $(basename "$t")"
done

# overlay（关自启的 uci-defaults）跟着一起盖
cp -a "$PLUGIN_DIR/overlay/." "$MNT/"
F=$MNT/etc/uci-defaults/zz-xxdiy-ddns-go-off
chown 0:0 "$F"
chmod 755 "$F"
log "uci-defaults：$F"

# ---- 3. 依赖 -------------------------------------------------------------
step "3/5 补依赖"
# ddns-go 的 Makefile 写的是 DEPENDS:=+ca-bundle（HTTPS 找 DNS 服务商要证书）。
# 镜像里本来就有，这里显式装一次，既是文档也是保险。
run_in_root 'apk --root /r add ca-bundle' || die "装 ca-bundle 失败"

# ---- 4. 关掉开机自启 -----------------------------------------------------
step "4/5 关掉开机自启"
n=0
for f in "$MNT"/etc/rc.d/S*"$SVC" "$MNT"/etc/rc.d/K*"$SVC"; do
    [ -e "$f" ] || continue
    rm -f "$f"
    log "删掉自启链接：$(basename "$f")"
    n=$((n + 1))
done
[ "$n" = 0 ] && log "本来就没有自启链接（我们没跑 postinst，正常）"

# ---- 5. 自检 -------------------------------------------------------------
step "5/5 自检"
bash "$PLUGIN_DIR/tests/verify.sh" "$MNT"

log "ddns-go 插件完成（默认不开机自启）"
