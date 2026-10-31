#!/bin/bash
# addons/xxdiy/plugins/ddns-go/fetch.sh —— 下载 ddns-go 的 release 资产并解出 data.tar
#
# 用法:
#   bash addons/xxdiy/plugins/ddns-go/fetch.sh
#
# 实际逻辑在 lib/fetch-ipk.sh（三个第三方插件共用），这里只是把插件目录和
# 缓存子目录名传进去。清单在 assets.txt。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$HERE/../../lib/fetch-ipk.sh" "$HERE" ddns-go
