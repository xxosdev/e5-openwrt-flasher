# addons/xxdiy

给 [e5-openwrt-flasher](../../README.md) 加插件的地方。

上游刷机包（`Openwrt_E5_Flasher_sleepN.zip`）是作者在真机上验过的，内核、rootfs、
boot.img 都是他调好的。**这里不重编任何东西**，只做一件事：

```
上游刷机包  ->  取出里面的 files/openwrt.ext4.gz
            ->  挂载 ext4，往里装插件（apk / overlay / 补丁）
            ->  重新打包
            ->  塞回上游刷机包，在 VERSION 末尾追加一段、重算 SHA256SUMS
```

好处是**和上游零冲突**：整个扩展层只新增文件，一个上游文件都不改，
`git fetch upstream && git merge` 永远不会有冲突，上游发 `sleep15` 时
只要把 `base_tag` 换成 `sleep15` 重跑一遍就行。

---

## 目录

```
addons/xxdiy/
├── build.sh                 # 上游包/镜像 -> 装了插件的 openwrt.ext4.gz
├── rebundle.sh              # 新 ext4.gz -> 新的刷机包 zip
├── lib/
│   ├── common.sh            # 公共函数（日志、docker、挂载、fsck）
│   ├── fetch-ipk.sh         # 下载 GitHub Release 资产、校验、解出 ipk 的 data.tar
│   ├── ipk.py               # ipk = ar 里套 data.tar.gz，这里只取文件树
│   └── sums.py              # 重算 SHA256SUMS（设备端 e5-upgrade 会校验）
├── plugins/
│   ├── ddns-go/             # ddns-go + LuCI（第三方，解包铺文件）
│   │   ├── assets.txt       # release 资产清单（URL 字节数 sha256 ipk 前缀）
│   │   ├── fetch.sh
│   │   ├── install.sh
│   │   ├── overlay/etc/uci-defaults/zz-xxdiy-ddns-go-off
│   │   └── tests/verify.sh
│   ├── easytier/            # EasyTier + LuCI（第三方，解包铺文件，同上）
│   │   ├── assets.txt
│   │   ├── fetch.sh
│   │   ├── install.sh
│   │   ├── overlay/etc/uci-defaults/zz-xxdiy-easytier-off
│   │   └── tests/verify.sh
│   ├── filemanager/         # LuCI 文件管理器（官方源里有，apk add 即可）
│   │   ├── install.sh
│   │   └── tests/verify.sh
│   ├── ipv6-default/        # 让「禁用 IPv6」默认是关
│   │   ├── install.sh
│   │   ├── overlay/etc/uci-defaults/90-xxdiy-ipv6
│   │   └── tests/verify.sh
│   └── passwall2/           # passwall2 + xray
│       ├── install.sh       # 插件入口（契约见下）
│       ├── fetch.sh         # 下载并校验 apk
│       ├── apks.txt         # apk 清单（文件名 字节数 sha256）
│       ├── patch/           # 对镜像里文件的补丁
│       ├── overlay/         # 直接盖进镜像的文件
│       └── tests/verify.sh  # 装完逐项核对
├── cache/                   # 下载的 apk / 基座 rootfs（git 忽略）
└── work/                    # 中间产物（git 忽略）
```

## 插件契约

新加一个插件 = 新建 `plugins/<名字>/install.sh`，它会被 `build.sh` 按目录名字典序调用：

```sh
install.sh <镜像挂载点>
```

环境变量由 `build.sh` 提供：

| 变量 | 含义 |
|---|---|
| `XXDIY_LIB` | `lib/common.sh` 的路径，`source` 它就有 `log/die/run_in_root/...` |
| `XXDIY_PLUGIN_DIR` | 当前插件目录 |
| `XXDIY_MNT` | 镜像挂载点 |
| `XXDIY_CACHE` | 缓存目录 |
| `XXDIY_TAG` | 版本后缀，如 `xxdiy.20261031` |

要求：

- **必须幂等**。在已经装好的镜像上再跑一遍，结果要一样。
- 装 apk 一律走 `run_in_root`（在 arm64 用户态里 `apk --root /r ...`），
  不要在宿主机上碰 apk。
- 装完自己核对一遍，别把问题留到刷机之后。

## 怎么跑

### 本地

```sh
# 需要 root（要 loop 挂载 ext4）、docker（跑 arm64 的 apk）、e2fsprogs、zip
sudo bash addons/xxdiy/build.sh Openwrt_E5_Flasher_sleep14.zip
sudo bash addons/xxdiy/rebundle.sh Openwrt_E5_Flasher_sleep14.zip \
     addons/xxdiy/work/openwrt-*.ext4.gz ./Openwrt_E5_Flasher_xxdiy.zip
```

`build.sh` 的输入也可以是 URL、`openwrt.ext4.gz`、裸 ext4 镜像。

国内网络可以：

```sh
sudo XXDIY_WRT_MIRROR=https://mirrors.ustc.edu.cn/openwrt \
     XXDIY_PASSWALL_LOCAL=/path/to/apks \
     bash addons/xxdiy/build.sh ...
```

### GitHub Actions

`.github/workflows/xxdiy.yml`，**只手动触发**（Actions 页面 -> Run workflow）：

| 输入 | 说明 |
|---|---|
| `base_tag` | 上游刷机包的 tag，默认 `e5-sleep14` |
| `base_zip` | 直接给 zip 的 URL（留空则按 tag 自动找） |
| `vanilla` | 勾上则额外产出一个「原版转存包」（上游 zip 原样另存，不装插件） |
| `publish` | 勾上则建 **draft** Release（真机验过再手动 Publish） |

> `vanilla` 不是「从源码编原版」——内核和 rootfs 都不在仓库里，编不出来。
> 它是把上游 zip 原样另存一份，用来证明流水线没把上游包弄坏，顺便留个退路。

## passwall2 插件做了什么

只装 **xray** 这一条线（用户明确不要 shadowsocksr / simple-obfs / v2ray-plugin / haproxy）。
装了 7 个 apk：`luci-app-passwall2`、中文语言包、`xray-core`、`geoview`、`tcping`、
`v2ray-geoip`、`v2ray-geosite`。

按严重程度，解决了四件事：

### 1. dnsmasq 基础版没有 nftset（最致命）

passwall2 的 ACL 用的那个 dnsmasq 实例需要 `nftset` 编译选项。E5 镜像里是**基础版**
`dnsmasq 2.93-r1`，没有它 -> 实例起不来 -> 53 端口被重定向到一个死端口 ->
**整机 DNS 全灭**（`ping 域名` 报 bad address，`ping IP` 正常）。

而且 `0_default_config` 里 `dns_redirect` 默认就是开的，所以这是**默认路径**，不是可选项。

处理：`apk del dnsmasq` + `apk add dnsmasq-full`（`dnsmasq-full` 的 PKGINFO 里
`PROVIDES:=dnsmasq`，`PACKAGE_dnsmasq_full_nftset` 默认 `y`），
并断言 `/etc/apk/world` 里是 `dnsmasq-full`、没有 `dnsmasq`。

### 2. 升级会把基础版搬回来

`package/device-install-image.sh` 的 `carry_packages()` 在 `--update` 时，
会把「旧系统里有、新系统里没有」的包搬回来——基础版 `dnsmasq` 正好符合，
于是 `dnsmasq-full` 被顶掉，DNS 又坏。

处理：往 `/etc/e5/apk-removed.list` 里加 `dnsmasq`（这个文件就是干这个的，
`carry_packages()` 会用 `grep -vxF -f` 把它过滤掉）。

### 3. 内核 `=y` 导致 passwall2 误判「缺组件」

E5 内核（`6.18.54-e5-sleep14-charles`）里这些全是 `=y`，所以 `lsmod` 里永远看不到：

```
CONFIG_NFT_TPROXY=y   CONFIG_NFT_SOCKET=y   CONFIG_NFT_REDIR=y
CONFIG_NF_NAT=y       CONFIG_IP_SET=y       CONFIG_NF_CONNTRACK=y
```

passwall2 靠 `lsmod` 判断，于是三处误判：

| 文件 | 行 | 症状 |
|---|---|---|
| `client/global.lua` | 组件总开关 | Localhost Proxy / Client Proxy 变灰 + 红字「Missing components」 |
| `client/other.lua` | 组件总开关 | 整个「TCP Proxy Way」下拉框**消失**，连 REDIRECT/TPROXY 都选不了 |
| `client/other.lua` | IPv6 开关 | 「IPv6 TProxy」复选框**根本不出现**（它判断的是 `ip6table_mangle` 或 `nft_tproxy`，两个都不在 `lsmod` 里） |

前两处是**同一行代码**；第三处嵌在它里面，是另一行，得单独补。
`iptables.sh` 里还有两处同样的 `lsmod | grep`，但只在 iptables 后端生效——
我们用 nftables（`prefer_nft=1` + `fw4` + `dnsmasq-full` 的 `nftset`），走不到那里。

处理：`patch/tproxy-detect.py` 在判定语句前插一个哨兵文件判断：

```lua
local _xxdiy_builtin = io.open("/etc/e5/xxdiy/nft-tproxy-builtin")
if _xxdiy_builtin then _xxdiy_builtin:close() end
if _xxdiy_builtin or (mods:find(...) ...) then
```

第三处复用同一个 local（作用域是整个 chunk），写成
`if _xxdiy_builtin or mods:find("ip6table_mangle") or mods:find("nft_tproxy") then`；
万一第一处没打上，Lua 读未定义变量得 `nil`，会退回原生判断，不会报错。

- 幂等：**按处**判断（看补丁后的特征片段），不是整份文件跳过——
  老版本脚本只打过前两处，新脚本会补上第三处
- 可逆：内核哪天改回 `=m`，删掉哨兵文件就恢复原生判断
- 不掩盖真问题：哨兵不在、`lsmod` 也没有，照样报缺组件
- 找不到原文时**硬失败**并把相关的行打出来，不会静默跳过

### 4. `app.sh` 检查的 `kmod-*.list` 在 apk v3 下不存在

`app.sh` 会检查 `/lib/apk/packages/kmod-nft-{socket,tproxy,nat}.list` 非空。
那是 apk v2 的产物，OpenWrt 25.12 用 apk v3，根本不生成。
处理：造三个占位文件（它只检查非空）。

### 5. 远程 DNS 查询策略默认是 `UseIPv4`

`0_default_config` 里 `remote_dns_query_strategy` 默认 `UseIPv4` —— 只向远程 DNS 要 A 记录，
双栈站点就解析不到 IPv6 地址。`direct_dns_query_strategy` 本来就是 `UseIP`，只有 remote 这一项不对。

处理：`patch/dns-query-strategy.py` 把三处都改成 `UseIP`：

| 文件 | 作用 |
|---|---|
| `usr/share/passwall2/0_default_config` | uci 第一次建配置时照它写，**真正生效**的那个 |
| `.../client/global.lua` | 界面上的默认值（uci 里没有这一项时才用得上） |
| `usr/share/passwall2/app_acl.lua` | ACL 读不到配置时的兜底 |

### 另外两点

- **`luci-lua-runtime` 显式装上**。passwall2 的界面是 Lua CBI，缺了它页面白屏。
- **不装 passwall 的 apk 源**。装了的话 `apk upgrade luci-app-passwall2` 会把 Lua 补丁冲掉。
  代价是 geoip/geosite 不自动更新，跟刷机包走。

## filemanager 插件做了什么

`luci-app-filemanager` 是 **openwrt/luci 官方仓库里的应用**
（`applications/luci-app-filemanager`），25.12.5 的 `aarch64_generic` 源里就有现成的 apk。
所以这个插件只有一步：`apk add`。不用下载、不用校验 sha256、不用打补丁、不用改 uci。

| 包 | 装完大小 | 依赖 |
|---|---|---|
| `luci-app-filemanager` | 88 KiB | `libc`、`luci-base`（镜像里都有） |
| `luci-i18n-filemanager-zh-cn` | 几 KB | — |

它是**纯 JS** 的 LuCI 应用：`htdocs/` 里的 JS + `menu.d` 的菜单 + `acl.d` 的权限，
没有 Lua、没有自己的后端。文件操作全部走 ubus 的 `file` 对象
（`rpcd-mod-file` 提供的 `/usr/lib/rpcd/file.so`），镜像里本来就装了，
所以不需要任何额外依赖。

装完菜单出现在 **系统 → 文件管理器**（`admin/system/filemanager`）。

> ⚠ **版本钉在 `26.303.28702~0229375`**。25.12.5 的 feed 是冻结的，一般不会变；
> 万一 OpenWrt 重建了源，构建会明确报错而不是悄悄装成别的版本。
> 换版本：`XXDIY_FILEMANAGER_VER=<新版本> bash addons/xxdiy/build.sh ...`

> 顺带一句：`CONFIG_PACKAGE_luci-app-filemanager=y` 是 **buildroot 编译期**的写法。
> 我们不编译，所以等价操作就是 `apk add luci-app-filemanager`，装出来的东西一样。

> 🔒 **安全提醒**：这是个 **root 权限**的文件管理器，能看到、改到整个文件系统。
> LuCI 的登录口令就是它的唯一门槛，别用弱口令，也别把 LuCI 暴露到公网。

## ipv6-default 插件做了什么

只放一个 uci-defaults：`/etc/uci-defaults/90-xxdiy-ipv6`，首次开机把
`e5-plugin-noipv6.settings.enabled` 写成 `0`，让信息屏「设置 → 网络 → 禁用 IPv6」
默认是**关**（也就是 IPv6 开箱可用）。

为什么要这么绕：这个默认值在信息屏里是写死的「缺省 = 1」——

~~~js
// /usr/share/e5-infoscreen/settings.uc
let on = (k) => (c.get('e5-plugin-noipv6','settings',k) ?? '1') != '0';
~~~

~~~sh
# /usr/libexec/e5-ipv6
setting() { [ "$(uci -q get $CFG.settings.$1 || echo 1)" != 0 ] && echo 1 || echo 0; }
~~~

全新镜像里 `/etc/config/e5-plugin-noipv6` 不存在，于是开机时 `e5-ipv6 sync`
会把 IPv6 关掉，开关也显示「开」。

**不改上游那两个文件**，只在首次开机时把值显式写出来。两个刻意的限制：

- 只在「还没设过」时写 —— 用户自己拨过开关、或者上游哪天把默认改掉，都不覆盖
- 只写 `enabled`，不动 `wan_ipv4` / `filter_aaaa`（那两个是「禁用时怎么禁」的细分开关，
  用户手动打开禁用时仍按默认 1 生效）

想恢复成「默认禁用 IPv6」：把 `plugins/ipv6-default/` 删掉重新构建即可。

## 第三方插件（ddns-go / easytier）为什么要解包

这两个不在官方 25.12.5 源里，只有 GitHub Release。而且**不能走 `apk add`**：

| 插件 | 情况 |
|---|---|
| `ddns-go` | 有 ipk（24.10）也有 apk（SNAPSHOT）两套，其实 apk 也能装 |
| `easytier` | 包声明 `+kmod-tun`。我们内核 `CONFIG_TUN=y`（编进去了，`/dev/net/tun` 在，实测 `ip tuntap add` 能建），所以官方源里**根本没有 kmod-tun 这个包**，`apk add` 一定报依赖不可满足 |

apk 3 也没有 `--no-depends` 这种忽略依赖的开关（force 系列只有 `--force-broken-world` 之类）。
所以两个统一走「解包铺文件」：

```
assets.txt（URL + 字节数 + sha256 + ipk 前缀）
  -> lib/fetch-ipk.sh  下载、校验、解 zip/tar
  -> lib/ipk.py        只挑匹配前缀的 ipk，取出 data.tar
  -> install.sh        用 tar 铺进 ext4
```

好处：绕开依赖解析、签名、postinst，也不受 24.10 / 22.03 与 25.12 的包格式差异影响。
代价：**没有 apk 数据库记录**（`apk list` 里看不到它们），依赖要自己保证。

sha256 取自 GitHub API 的 asset `digest` 字段，不是下载后自己算的 —— 所以清单可以先写好再跑。

### 默认不开机自启

两个插件都要求默认关闭，做法是两层：

1. **构建时**：删掉 `/etc/rc.d/S*<服务>`、`K*<服务>`。我们没跑 postinst，本来就不会有，删是兜底。
2. **开机时**：`zz-xxdiy-<服务>-off` 这个 uci-defaults 再 `stop` + `disable` 一次。

第 2 层对 easytier 是**必需**的：上游 `/etc/uci-defaults/luci-easytier` 里明确写了
`/etc/init.d/easytier enable`。uci-defaults 按文件名字典序跑，`zz-` 排在 `luci-` 之后才关得掉。
（ddns-go 的 `99-luci-ddns-go` 只 chmod + 重启 rpcd，不 enable。）

### 依赖

| 插件 | 需要 | 镜像里 |
|---|---|---|
| `ddns-go` | `ca-bundle`（HTTPS 找 DNS 服务商） | 有，显式再装一次当文档 |
| `easytier` | `luci-compat` + `luci-lua-runtime`（界面是 Lua CBI） | 有，但**插件顺序在前**，所以自己装 |

> ⚠ 插件按目录名字典序跑：`ddns-go` → `easytier` → `filemanager` → `ipv6-default` → `passwall2`。
> easytier 排在 passwall2 前面，不能指望 passwall2 顺手把 `luci-compat` 装上。

## 已知限制

- **不能加内核模块**。OpenWrt 官方的 `kmods` feed 是给内核 **6.12.94** 编的，
  E5 跑的是 **6.18.54-e5-sleep14-charles**，版本对不上，`.ko` 加载不了。
  好消息是常用能力（WireGuard / TUN / PPP / nftables 全套 / IP_SET）都已经 `=y` 编进内核了。
- **不能改内核配置、boot.img、OpenWrt 大版本**。要改这些只能重编内核 + rootfs，
  那是另一条完全不同的路（见 `e5-linux` 的 `openwrt-release.yml`）。
- `build.sh` 需要 root 和 docker。CI 上没 docker 的机器跑不了。

## 排查

| 现象 | 先看什么 |
|---|---|
| `apk add` 报 unsatisfiable | 看日志里 `--simulate` 打出来的解析计划，缺的是哪个包 |
| `dnsmasq --version` 里有 `no-nftset` | `dnsmasq-full` 没装上，看 `apk --root /r info dnsmasq-full` |
| LuCI 里 passwall2 页面白屏 | `luci-lua-runtime` 没装 |
| 透明代理选项灰着 / 没有 TCP Proxy Way | 哨兵文件在不在，Lua 补丁打没打 |
| 网页升级报「校验失败：刷机包已损坏」 | `rebundle.sh` 有没有重算 `SHA256SUMS` |
| 刷完 ping 域名 bad address、ping IP 正常 | dnsmasq 又变回基础版了，看 `/etc/e5/apk-removed.list` |
| 文件管理器能打开、点文件就报错 | `rpcd-mod-file` 在不在（`/usr/lib/rpcd/file.so`） |
| 信息屏「禁用 IPv6」默认还是开 | `ipv6-default` 插件没跑，或 `/etc/config/e5-plugin-noipv6` 里 `enabled=1` |
| 双栈站点只有 IPv4 能通、IPv6 解析不到 | `uci get passwall2.@global[0].remote_dns_query_strategy` 应为 `UseIP` |
| `apk add easytier` 报 `kmod-tun` 不可满足 | 正常，别用 apk。走插件解包，TUN 是内建的 |
| 刷完 ddns-go / easytier 自己起来了 | 看 `/etc/rc.d` 里有没有 `S*<服务>`，以及 `zz-xxdiy-*-off` 有没有跑（`ls /etc/uci-defaults/`） |
| easytier 页面白屏 | `luci-compat` / `luci-lua-runtime` 没装 |
