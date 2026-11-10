#!/usr/bin/env python3
"""Write src/testdata/list_date_modified.DS_Store: a minimal Finder store
whose folder `child` has an icon view arranged by name and a list view
sorted by date modified, newest first. Standard library only."""

import pathlib
import plistlib
import struct


def record(name, code, kind, data):
    units = name.encode("utf-16-be")
    out = struct.pack(">I", len(units) // 2) + units + code + kind
    if kind == b"blob":
        out += struct.pack(">I", len(data))
    return out + data


def main():
    icvp = plistlib.dumps({"arrangeBy": "name"}, fmt=plistlib.FMT_BINARY)
    lsvc = plistlib.dumps(
        {
            "sortColumn": "dateModified",
            "columns": [
                {"identifier": "name", "ascending": True},
                {"identifier": "dateModified", "ascending": False},
            ],
        },
        fmt=plistlib.FMT_BINARY,
    )
    # Records sort by name, then code: icvp before lsvC.
    leaf = struct.pack(">II", 0, 2)
    leaf += record("child", b"icvp", b"blob", icvp)
    leaf += record("child", b"lsvC", b"blob", lsvc)
    master = struct.pack(">IIIII", 2, 0, 2, 1, 0x1000)

    # Blocks live at offsets from file offset 4; each block's address is its
    # offset with log2(size) in the low 5 bits.
    block_size = 4096
    offsets = [block_size * 1, block_size * 2, block_size * 3]
    addresses = [o | 12 for o in offsets]  # 1 << 12 == 4096

    bookkeeping = struct.pack(">II", len(addresses), 0)
    bookkeeping += b"".join(struct.pack(">I", a) for a in addresses)
    bookkeeping += b"\0" * 4 * (256 - len(addresses))
    bookkeeping += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    bookkeeping += b"\0" * 4 * 32  # 32 empty free lists

    body = bytearray(block_size * 4)
    for offset, data in zip(offsets, [bookkeeping, master, leaf]):
        assert len(data) <= block_size
        body[offset : offset + len(data)] = data
    header = b"Bud1" + struct.pack(">III", offsets[0], len(bookkeeping), offsets[0])
    body[0 : len(header)] = header
    out = b"\x00\x00\x00\x01" + bytes(body)

    path = pathlib.Path(__file__).resolve().parent.parent / "src/testdata"
    path.mkdir(parents=True, exist_ok=True)
    (path / "list_date_modified.DS_Store").write_bytes(out)


if __name__ == "__main__":
    main()
