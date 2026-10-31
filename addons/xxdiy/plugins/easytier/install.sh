#!/bin/bash
# addons/xxdiy/plugins/easytier/install.sh —— 把 EasyTier 和它的 LuCI 界面装进镜像
#
# 插件契约：install.sh <镜像挂载点>
#   build.sh 会设置 XXDIY_LIB / XXDIY_PLUGIN_DIR / XXDIY_MNT / XXDIY_TAG
#   必须幂等：在已经装好的镜像上再跑一遍，结果要一样。
#
# 为什么不走 apk：
#   easytier 的包声明了 `+kmod-tun`。我们的内核 CONFIG_TUN=y（编进去了，
#   /dev/net/tun 在，实测 ip tuntap add 能建），所以官方源里根本没有 kmod-tun
#   这个包 —— apk add 一定报依赖不可满足。解包铺文件绕开依赖解析，功能一点不缺。
#
# 默认不会跑核心 —— 但**不是靠关自启做到的**，靠的是上游配置本身：
#   /etc/config/easytier 出厂就是 enabled='0' / web_enabled='0'，
#   init 脚本 start_service() 里是
#       [ "$(uci -q get easytier.@easytier[0].enabled)" = "1" ] && start_et easytier
#   两个都是 0，所以就算 rc.d 里有 S99easytier，开机也只是空跑一遍就返回。
#
# 所以这里**故意不 disable**：
#   上游 /etc/uci-defaults/luci-easytier 会在首次开机 `/etc/init.d/easytier enable`
#   建出 S99easytier。而 LuCI 那边（controller 的 toggleCore / restart_service）
#   只会调 start / restart，**从不调 enable**。要是我们把 enable 关掉，
#   用户以后在页面里勾了「启用」→ 当下能跑，一重启又没了，得手动去
#   「系统→启动项」里再打开一次。留着上游的 enable 才是对的。
set -euo pipefail

MNT=${1:?用法: install.sh <镜像挂载点>}
. "${XXDIY_LIB:?build.sh 没有设置 XXDIY_LIB}"
PLUGIN_DIR=${XXDIY_PLUGIN_DIR:?build.sh 没有设置 XXDIY_PLUGIN_DIR}
export XXDIY_MNT=$MNT

[ -d "$MNT/etc" ] || die "挂载点看起来不对：$MNT"
ensure_docker

SVC=easytier
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
    tar -xpf "$t" -C "$MNT" --numeric-owner || die "铺失败：$t"
    log "铺了 $(basename "$t")"
done

# init 脚本要有可执行位（上游的 postinst 也会 chmod，我们不跑 postinst）
chmod 755 "$MNT/etc/init.d/$SVC" 2>/dev/null || warn "没找到 /etc/init.d/$SVC"

# ---- 3. 依赖 -------------------------------------------------------------
step "3/5 补依赖"
# LuCI 界面是 Lua CBI（luasrc/），25.12 上要靠 luci-compat 提供兼容层，
# 再靠 luci-lua-runtime 跑 Lua 页面。两个都是官方包，很小。
# 注意插件是按目录名字典序跑的，easytier 排在 passwall2 前面，
# 不能指望 passwall2 顺手把它们装上，所以这里自己装。
run_in_root 'apk --root /r add luci-compat luci-lua-runtime' \
    || die "装 luci-compat / luci-lua-runtime 失败"

# ---- 4. 清掉构建时可能残留的自启链接 -------------------------------------
step "4/5 清掉构建时可能残留的自启链接"
n=0
for f in "$MNT"/etc/rc.d/S*"$SVC" "$MNT"/etc/rc.d/K*"$SVC"; do
    [ -e "$f" ] || continue
    rm -f "$f"
    log "删掉自启链接：$(basename "$f")"
    n=$((n + 1))
done
[ "$n" = 0 ] && log "本来就没有（我们没跑 postinst，正常）"
log "首次开机上游 luci-easytier 会 enable 建出 S99，这是上游设计，不用管："
log "  enabled='0' 时 start_service() 直接返回，核心不会起来"

# ---- 5. 自检 -------------------------------------------------------------
step "5/5 自检"
bash "$PLUGIN_DIR/tests/verify.sh" "$MNT"

log "easytier 插件完成（默认不启动：配置里 enabled='0'）"
