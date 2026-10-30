#!/usr/bin/env python3
"""重算刷机包顶层目录的 SHA256SUMS。

设备端（overlay/*/usr/libexec/e5-upgrade）是这样校验的：

    T=$(top)                       # zip 里唯一的那个 <顶层>/files/boot.json 的上一层
    (cd "$T" && sha256sum -c -s SHA256SUMS)

所以 SHA256SUMS 必须放在**顶层目录**里，里面记的路径**相对顶层目录**
（例如 `files/openwrt.ext4.gz`）。换成新的 ext4.gz 之后不重算的话，
网页升级会直接报「校验失败：刷机包已损坏」。

用法: sums.py <顶层目录>
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

SKIP_DIRS = {"__MACOSX"}
SKIP_NAMES = {".DS_Store", "SHA256SUMS"}
CHUNK = 1 << 20


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("用法: sums.py <顶层目录>", file=sys.stderr)
        return 2

    top = Path(argv[1]).resolve()
    if not (top / "files" / "boot.json").is_file():
        print(f"不是刷机包顶层目录（缺 files/boot.json）：{top}", file=sys.stderr)
        return 1

    entries: list[tuple[str, str]] = []
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if name in SKIP_NAMES:
                continue
            p = Path(dirpath) / name
            # 符号链接不列：sha256sum -c 会跟随，列出来反而容易和包里的实际内容不一致
            if p.is_symlink() or not p.is_file():
                continue
            entries.append((p.relative_to(top).as_posix(), sha256_of(p)))

    entries.sort(key=lambda e: e[0])

    out = top / "SHA256SUMS"
    with out.open("w", encoding="utf-8", newline="\n") as f:
        for rel, digest in entries:
            f.write(f"{digest}  {rel}\n")

    print(f"SHA256SUMS: {len(entries)} 个文件 -> {out}")
    for rel, digest in entries:
        print(f"  {digest[:16]}...  {rel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
