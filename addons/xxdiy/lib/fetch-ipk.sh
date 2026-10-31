#!/bin/bash
# addons/xxdiy/lib/fetch-ipk.sh —— 通用下载器：GitHub Release 资产 -> ipk 的 data.tar
#
# 用法:
#   bash addons/xxdiy/lib/fetch-ipk.sh <插件目录> <缓存子目录名>
#
# 读 <插件目录>/assets.txt，每行:
#
#   <文件名> <URL> <字节数> <sha256> <ipk 前缀,逗号分隔>
#
# 以 # 开头和空行忽略。流程：
#   1. 下载（断点续传，4 轮重试），按字节数 + sha256 校验
#   2. 解压缩包，只挑文件名匹配前缀的 ipk
#   3. 把每个 ipk 的 data.tar 解到缓存目录，命名 <包名>.data.tar
#
# 校验不通过宁可不出包，也不出一个来源不明的包。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"

PLUGIN_DIR=${1:?用法: fetch-ipk.sh <插件目录> <缓存子目录名>}
CACHE_NAME=${2:?用法: fetch-ipk.sh <插件目录> <缓存子目录名>}
LIST=$PLUGIN_DIR/assets.txt
DEST=$XXDIY_CACHE/$CACHE_NAME
mkdir -p "$DEST"

[ -f "$LIST" ] || die "找不到清单：$LIST"
command -v python3 >/dev/null 2>&1 || die "需要 python3（解 ipk 用）"

verify() { # <文件> <字节数> <sha256>
    [ -f "$1" ] || return 1
    [ "$(stat -c %s "$1" 2>/dev/null)" = "$2" ] || return 1
    [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$3" ] || return 1
}

download() { # <url> <输出文件> <字节数> <sha256>
    local url=$1 out=$2 bytes=$3 sha=$4 i got
    if verify "$out" "$bytes" "$sha"; then
        log "已存在且校验通过：$(basename "$out")"
        return 0
    fi
    for i in 1 2 3 4; do
        log "下载 $(basename "$out")（第 $i 次）"
        # -C - 断点续传：GitHub 到国内经常断在半路
        if curl -fL -C - --connect-timeout 30 --max-time 1800 \
                --retry 2 --retry-delay 5 -o "$out" "$url"; then
            if verify "$out" "$bytes" "$sha"; then
                log "校验通过：$(basename "$out")"
                return 0
            fi
            got=$(stat -c %s "$out" 2>/dev/null || echo '?')
            warn "校验不通过（$got 字节 / 期望 $bytes），删掉重下"
            rm -f "$out"
        else
            warn "下载失败（第 $i 次）"
        fi
        sleep 5
    done
    die "下载失败：$url"
}

while read -r name url bytes sha prefixes; do
    case "${name:-}" in ''|'#'*) continue ;; esac
    [ -n "${prefixes:-}" ] || die "assets.txt 这一行缺 ipk 前缀：$name"
    [ -n "${sha:-}" ] || die "assets.txt 这一行缺 sha256：$name"

    file=$DEST/$name
    download "$url" "$file" "$bytes" "$sha"

    log "解包 $name"
    # 前缀用逗号分隔，换成空格展开成多个参数
    # shellcheck disable=SC2086
    python3 "$HERE/ipk.py" unpack "$file" "$DEST" ${prefixes//,/ } \
        || die "解包失败：$name"
done < "$LIST"

echo
log "缓存目录 $DEST 里现在有："
ls -la "$DEST" | sed 's/^/    /'
