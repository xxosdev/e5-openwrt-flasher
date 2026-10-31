#!/bin/bash
# addons/xxdiy/plugins/easytier/fetch.sh —— 下载 EasyTier 的 release 资产并解出 data.tar
#
# 用法:
#   bash addons/xxdiy/plugins/easytier/fetch.sh
#
# 实际逻辑在 lib/fetch-ipk.sh（三个第三方插件共用），清单在 assets.txt。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$HERE/../../lib/fetch-ipk.sh" "$HERE" easytier
