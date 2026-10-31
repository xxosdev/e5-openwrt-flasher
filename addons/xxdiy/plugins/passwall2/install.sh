#!/bin/bash
# addons/xxdiy/plugins/passwall2/install.sh —— 把 passwall2（只带 xray）装进镜像
#
# 插件契约：install.sh <镜像挂载点>
#   build.sh 会设置 XXDIY_LIB / XXDIY_PLUGIN_DIR / XXDIY_MNT / XXDIY_TAG
#   必须幂等：在已经装好的镜像上再跑一遍，结果要一样。
#
# 这个脚本解决的问题，按严重程度排：
#
#   1. dnsmasq 基础版没有 nftset。passwall2 的 ACL 用的那个 dnsmasq 实例要 nftset，
#      起不来 -> 53 端口被重定向到一个死端口 -> 整机 DNS 全灭
#      （ping 域名 bad address，ping IP 正常）。而且 0_default_config 里
#      dns_redirect 默认就是开的，所以这是默认路径，不是可选项。
#      -> 必须换成 dnsmasq-full。
#
#   2. E5 内核把 NFT_TPROXY / NFT_SOCKET / NFT_REDIR 编成 =y，lsmod 里永远看不到，
#      passwall2 误判「缺组件」：
#        client/global.lua  -> Localhost/Client Proxy 变灰 + 红字
#        client/other.lua   -> 整个「TCP Proxy Way」选择器消失
#      -> patch/tproxy-detect.py 打补丁，用哨兵文件放行。
#
#   3. app.sh 还会检查 /lib/apk/packages/kmod-nft-*.list 非空。
#      apk v3 根本不生成这些文件 -> 造占位文件。
#
#   4. 升级保留：device-install-image.sh 的 carry_packages() 会把旧系统里有、
#      新系统里没有的包搬回来。基础版 dnsmasq 会被搬回来顶掉 dnsmasq-full
#      -> 往 /etc/e5/apk-removed.list 里加 dnsmasq。
#
#   5. 远程 DNS 查询策略默认是 UseIPv4（只问 A 记录），双栈站点解析不到 IPv6。
#      -> patch/dns-query-strategy.py 把三处默认值都改成 UseIP。
set -euo pipefail

MNT=${1:?用法: install.sh <镜像挂载点>}
. "${XXDIY_LIB:?build.sh 没有设置 XXDIY_LIB}"
PLUGIN_DIR=${XXDIY_PLUGIN_DIR:?build.sh 没有设置 XXDIY_PLUGIN_DIR}
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"
ensure_docker

# ---- 0. 准备 apk ---------------------------------------------------------
step "准备 apk"
# fetch.sh 自己幂等：已存在且 sha256 对得上的直接跳过
bash "$PLUGIN_DIR/fetch.sh"

have_pkg() {
    run_in_root "apk --root /r info -e $1 >/dev/null 2>&1" >/dev/null 2>&1
}

# ---- 1. dnsmasq -> dnsmasq-full -----------------------------------------
step "换 dnsmasq-full（基础版没有 nftset，passwall2 会起不来）"
if have_pkg dnsmasq-full; then
    log "dnsmasq-full 已经在了"
else
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
# OpenWrt 文档里的顺序就是先 del 再 add（两个包都提供 /usr/sbin/dnsmasq，
# 同时存在会撞文件）。del 有可能被反向依赖挡住，那也继续试 add。
echo "--- 删掉基础版 dnsmasq ---"
if apk --root /r del dnsmasq; then
    echo "已删除 dnsmasq"
else
    echo "del dnsmasq 失败（可能有反向依赖挡着），继续尝试直接装 full"
fi
echo "--- 装 dnsmasq-full ---"
if ! apk --root /r add dnsmasq-full; then
    echo "!! dnsmasq-full 装不上，看上面的 apk 报错"
    restore
    exit 1
fi
restore
# 不能在 chroot 里跑 `dnsmasq --version`：它启动时要读 /dev/urandom 来播种随机数，
# 而镜像里的 /dev 是空的（开机才由内核挂 devtmpfs），于是只会得到
# "failed to seed the random number generator"，什么版本信息都没有。
# 改成直接 grep 二进制里的编译选项字符串：dnsmasq 的 version 输出就是这些常量，
# 有 nftset 编进去时字面量是 "nftset "，没有时是 "no-nftset "。
B=/r/usr/sbin/dnsmasq
[ -x "$B" ] || { echo "!! 没有 /usr/sbin/dnsmasq"; exit 1; }
if grep -aq 'no-nftset' "$B"; then
    echo "!! 二进制里是 no-nftset，装的还是基础版"; exit 1
fi
grep -aq 'nftset' "$B" || { echo "!! 二进制里找不到 nftset 字样"; exit 1; }
echo "OK：dnsmasq 二进制带 nftset"
' -e "XXDIY_WRT_MIRROR=${XXDIY_WRT_MIRROR:-}"
fi

# ---- 2. 装 passwall2 和 xray --------------------------------------------
step "装 passwall2 / xray"
if have_pkg luci-app-passwall2; then
    log "luci-app-passwall2 已经在了，跳过安装"
else
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
echo "--- 本地包 ---"
ls -1 /cache/passwall2/*.apk
# luci-lua-runtime 显式带上：passwall2 的界面是 Lua CBI，缺了它页面白屏。
# 它本来应该被 luci-compat 拉进来，但显式写上更保险。
if ! apk --root /r add --allow-untrusted /cache/passwall2/*.apk luci-lua-runtime; then
    echo "=== apk add 失败，下面是解析计划，看谁不可满足 ==="
    apk --root /r add --simulate --allow-untrusted /cache/passwall2/*.apk luci-lua-runtime || true
    restore
    exit 1
fi
restore
echo "--- /lib/modules ---"
ls -1 /r/lib/modules | sed "s/^/  /"
# 装 kmod-* 会把给 6.12.94 编的 .ko 落到 /lib/modules/6.12.94/ 里（这次是
# kmod-nf-conntrack-netlink，dnsmasq-full 的 conntrack 功能要它）。E5 跑的是
# 6.18.54-e5-*，那个目录永远加载不到；而真正需要的 CONFIG_NF_CT_NETLINK
# 在内核里本来就是 =y。留着只会让 ls /lib/modules 出现两个版本，删掉。
for d in /r/lib/modules/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
        *-e5-*) : ;;
        *) echo "  删掉不匹配的模块目录：$(basename "$d")"; rm -rf "$d" ;;
    esac
done
echo "--- 清理后的 /lib/modules ---"
ls -1 /r/lib/modules | sed "s/^/  /"
'
fi

# ---- 3. 断言 -------------------------------------------------------------
step "断言关键包都在"
run_in_root '
set -e
bad=0
for p in luci-app-passwall2 luci-i18n-passwall2-zh-cn xray-core geoview tcping \
         v2ray-geoip v2ray-geosite dnsmasq-full luci-lua-runtime luci-compat; do
    if apk --root /r info -e "$p" >/dev/null 2>&1; then
        echo "  有 $p"
    else
        echo "  缺 $p"
        bad=1
    fi
done
[ "$bad" = 0 ] || exit 1
# /etc/apk/world 里必须是 dnsmasq-full，不能留着 dnsmasq，
# 否则以后 apk upgrade 会把基础版装回来
grep -qx "dnsmasq-full" /r/etc/apk/world || { echo "!! world 里没有 dnsmasq-full"; exit 1; }
if grep -qx "dnsmasq" /r/etc/apk/world; then echo "!! world 里还留着 dnsmasq"; exit 1; fi
echo "  world 正确：有 dnsmasq-full，没有 dnsmasq"
echo "--- xray ---"
chroot /r sh -c "xray version 2>&1 | head -2" || { echo "!! xray 跑不起来"; exit 1; }
'

# ---- 4. 升级保留：别让基础版 dnsmasq 回来 ---------------------------------
step "写 /etc/e5/apk-removed.list"
LISTF=$MNT/etc/e5/apk-removed.list
touch "$LISTF"
if grep -qx 'dnsmasq' "$LISTF"; then
    log "dnsmasq 已经在列表里"
else
    printf 'dnsmasq\n' >> "$LISTF"
    log "已加入 dnsmasq"
fi
log "现在的内容：$(tr '\n' ' ' < "$LISTF")"

# ---- 5. app.sh 要的 kmod 占位文件 ---------------------------------------
step "造 /lib/apk/packages/kmod-nft-*.list 占位文件"
REL=$(ls -1 "$MNT/lib/modules" | grep -E -- '-e5-' | head -1 || true)
[ -n "$REL" ] || REL=$(ls -1 "$MNT/lib/modules" 2>/dev/null | head -1 || true)
[ -n "$REL" ] || die "/lib/modules 是空的，镜像不对"
log "内核：$REL"
mkdir -p "$MNT/lib/apk/packages"
for m in socket tproxy nat; do
    printf '/lib/modules/%s/nft_%s.ko\n' "$REL" "$m" > "$MNT/lib/apk/packages/kmod-nft-$m.list"
    chown 0:0 "$MNT/lib/apk/packages/kmod-nft-$m.list"
    chmod 644 "$MNT/lib/apk/packages/kmod-nft-$m.list"
done
log "kmod-nft-socket / tproxy / nat 的 .list 已就位（app.sh 只检查非空）"

# ---- 6. overlay ----------------------------------------------------------
step "覆盖 overlay 文件"
cp -a "$PLUGIN_DIR/overlay/." "$MNT/"
chown -R 0:0 "$MNT/etc/e5/xxdiy" "$MNT/etc/uci-defaults/zz-xxdiy"
chmod 644 "$MNT/etc/e5/xxdiy/nft-tproxy-builtin"
chmod 755 "$MNT/etc/uci-defaults/zz-xxdiy"
log "哨兵：$MNT/etc/e5/xxdiy/nft-tproxy-builtin"
log "uci-defaults：$MNT/etc/uci-defaults/zz-xxdiy"

# ---- 7. Lua 补丁 ---------------------------------------------------------
step "打 Lua 补丁（tproxy 误判）"
python3 "$PLUGIN_DIR/patch/tproxy-detect.py" "$MNT"

# ---- 7b. DNS 查询策略默认值 ----------------------------------------------
step "改 DNS 查询策略默认值（UseIPv4 -> UseIP）"
python3 "$PLUGIN_DIR/patch/dns-query-strategy.py" "$MNT"

# ---- 8. 自检 -------------------------------------------------------------
step "自检"
bash "$PLUGIN_DIR/tests/verify.sh" "$MNT"

log "passwall2 插件完成"
