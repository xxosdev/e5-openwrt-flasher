#!/bin/bash
# addons/xxdiy/plugins/passwall2/fetch.sh —— 按 apks.txt 下载并校验 apk
#
# 用法:
#   bash addons/xxdiy/plugins/passwall2/fetch.sh
#
# 下载到 addons/xxdiy/cache/passwall2/（已存在且校验通过的直接跳过）。
# 支持断点续传；每个镜像最多试两轮；全部镜像都失败才退出非零。
#
# 环境变量:
#   XXDIY_CACHE            缓存目录
#   XXDIY_PASSWALL_BASE    换一个下载源（URL 前缀）
#   XXDIY_PASSWALL_LOCAL   本地目录，优先从这里拷（离线构建 / 复用已下好的包）
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$HERE/../../lib/common.sh"

LIST=$HERE/apks.txt
DEST=$XXDIY_CACHE/passwall2
mkdir -p "$DEST"

# 官方构建产物在 sourceforge。master.dl 是直链，比 /files/.../download 那种跳转稳。
BASES=()
[ -n "${XXDIY_PASSWALL_BASE:-}" ] && BASES+=("$XXDIY_PASSWALL_BASE")
BASES+=(
    "https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-25.12/aarch64_generic"
    "https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-25.12/aarch64_generic"
)

verify() { # <文件> <字节数> <sha256>
    [ -f "$1" ] || return 1
    [ "$(stat -c %s "$1")" = "$2" ] || return 1
    [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$3" ] || return 1
}

step "下载 passwall2 的 apk -> $DEST"
[ -f "$LIST" ] || die "找不到 $LIST"

ok=0
skip=0
fail=0
failed_names=""

while read -r name size sha; do
    [ -n "${name:-}" ] || continue
    dest=$DEST/$name

    if verify "$dest" "$size" "$sha"; then
        log "已有且校验通过：$name"
        skip=$((skip + 1))
        continue
    fi
    rm -f "$dest"

    # 本地目录优先
    if [ -n "${XXDIY_PASSWALL_LOCAL:-}" ] && [ -f "$XXDIY_PASSWALL_LOCAL/$name" ]; then
        if verify "$XXDIY_PASSWALL_LOCAL/$name" "$size" "$sha"; then
            cp -f "$XXDIY_PASSWALL_LOCAL/$name" "$dest"
            log "从本地拷入：$name"
            ok=$((ok + 1))
            continue
        fi
        warn "本地 $XXDIY_PASSWALL_LOCAL/$name 校验不符，改从网络下载"
    fi

    got=0
    for base in "${BASES[@]}"; do
        log "取 $name <- $base"
        # 第一轮断点续传
        if curl -fL -C - --retry 3 --retry-delay 3 --connect-timeout 30 \
                -o "$dest" "$base/$name"; then
            if verify "$dest" "$size" "$sha"; then got=1; break; fi
            warn "校验不符（$(stat -c %s "$dest" 2>/dev/null || echo 0) 字节，应为 $size），删掉重下"
            rm -f "$dest"
            # 第二轮：不用续传，从头来
            if curl -fL --retry 3 --retry-delay 3 --connect-timeout 30 \
                    -o "$dest" "$base/$name" && verify "$dest" "$size" "$sha"; then
                got=1
                break
            fi
            rm -f "$dest"
        else
            warn "从这个源下载失败"
        fi
    done

    if [ "$got" = 1 ]; then
        log "OK：$name（$size 字节）"
        ok=$((ok + 1))
    else
        fail=$((fail + 1))
        failed_names="$failed_names $name"
    fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$LIST" | awk 'NF >= 3 { print $1, $2, $3 }')

printf '\n'
log "新下载 $ok，已有 $skip，失败 $fail"
[ "$fail" = 0 ] || die "这些包没拿到：$failed_names"

step "缓存内容"
ls -la "$DEST"
