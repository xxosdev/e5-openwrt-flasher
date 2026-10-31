#!/usr/bin/env python3
"""解 OpenWrt 的 ipk，取出里面那棵文件树。

ipk 就是 ar 归档里套两个 tar.gz：

    !<arch>
      debian-binary     "2.0\\n"
      control.tar.gz    control / postinst / conffiles
      data.tar.gz       真正的文件树（./usr/bin/xxx 这种相对路径）

我们不需要 opkg/apk 的依赖解析和 postinst —— 镜像里的东西本来就是烧进去的，
只要那棵文件树，解出来用 tar 铺进 ext4 就行。这样顺带绕开了两个死结：
  * lucky 只有 ipk、根本没有 apk
  * easytier 声明了 kmod-tun，而我们的内核把 TUN 编进去了，没这个包

用法:
  ipk.py list   <ipk>
      列出 ar 成员，调试用。

  ipk.py unpack <压缩包> <输出目录> <ipk 前缀>...
      压缩包可以是 .tar.gz / .tgz / .tar / .zip，里面可以是一堆 ipk。
      只取文件名以给定前缀开头的 ipk（前缀能避免把 easytier-noweb 之类
      的变体也解进来），把它们的 data 解到输出目录，命名 <包名>.data.tar。
"""

from __future__ import annotations

import sys
import tarfile
import zipfile
from pathlib import Path

AR_MAGIC = b"!<arch>\n"


def read_ar(data: bytes) -> list[tuple[str, bytes]]:
    """把 ar 归档拆成 (成员名, 内容)。ipk 用的就是最朴素的 ar 格式。"""
    if not data.startswith(AR_MAGIC):
        raise SystemExit("不是 ar 归档（ipk 应该以 !<arch> 开头）")
    off, out = len(AR_MAGIC), []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        if hdr[58:60] != b"`\n":
            raise SystemExit(f"ar 头损坏，偏移 {off}")
        name = hdr[0:16].decode("utf-8", "replace").strip()
        if name.endswith("/"):          # GNU ar 会在名字后面加 /
            name = name[:-1]
        try:
            size = int(hdr[48:58].decode().strip())
        except ValueError:
            raise SystemExit(f"ar 成员大小解析失败：{hdr[48:58]!r}")
        out.append((name, data[off + 60: off + 60 + size]))
        off += 60 + size + (size & 1)   # 成员按偶数对齐
    return out


def iter_members(path: Path):
    """把压缩包里的文件逐个吐成 (名字, 内容)。"""
    low = path.name.lower()
    if low.endswith((".tar.gz", ".tgz", ".tar", ".tar.xz")):
        with tarfile.open(path, "r:*") as tf:
            for m in tf.getmembers():
                if m.isfile():
                    f = tf.extractfile(m)
                    if f is not None:
                        yield m.name, f.read()
    elif low.endswith(".zip"):
        with zipfile.ZipFile(path) as zf:
            for n in zf.namelist():
                if not n.endswith("/"):
                    yield n, zf.read(n)
    else:
        raise SystemExit(f"不认识的压缩包类型：{path.name}")


def cmd_list(ipk: Path) -> int:
    for name, body in read_ar(ipk.read_bytes()):
        print(f"  {name:20s} {len(body):>10,} 字节")
    return 0


def cmd_unpack(archive: Path, outdir: Path, prefixes: list[str]) -> int:
    outdir.mkdir(parents=True, exist_ok=True)
    got: list[Path] = []
    skipped: list[str] = []

    for member_name, content in iter_members(archive):
        base = Path(member_name).name
        if not base.endswith(".ipk"):
            continue
        if not any(base.startswith(p) for p in prefixes):
            skipped.append(base)
            continue

        pkg = base[:-4]                 # 去掉 .ipk
        data = None
        for aname, abody in read_ar(content):
            if aname.startswith("data.tar"):
                data = abody
                break
        if data is None:
            print(f"  [跳过] {base}：里面没有 data.tar*", file=sys.stderr)
            continue

        # 统一叫 .data.tar，不写死压缩格式；铺的时候用 tar -xf 自动识别
        dest = outdir / f"{pkg}.data.tar"
        dest.write_bytes(data)
        got.append(dest)
        print(f"  [解出] {base} -> {dest.name}（{len(data):,} 字节）")

    if skipped:
        print(f"  [未选] {', '.join(sorted(skipped))}")
    if not got:
        print(f"  [失败] {archive.name} 里没有任何 ipk 匹配前缀 {prefixes}", file=sys.stderr)
        return 1
    print(f"  共解出 {len(got)} 个包")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    mode, target = argv[1], Path(argv[2])
    if not target.is_file():
        print(f"文件不存在：{target}", file=sys.stderr)
        return 2
    if mode == "list":
        return cmd_list(target)
    if mode == "unpack":
        if len(argv) < 4:
            print("unpack 需要至少一个 ipk 前缀", file=sys.stderr)
            return 2
        return cmd_unpack(target, Path(argv[3]), argv[4:])
    print(f"不认识的模式：{mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
