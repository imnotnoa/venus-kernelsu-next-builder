#!/usr/bin/env python3
"""Check that a freshly built kernel can load the ROM's prebuilt vendor modules.

The Mi 11 (venus) runs a non-GKI 5.4 kernel with CONFIG_MODVERSIONS=y. The
display, touch and audio drivers are prebuilt modules that ship inside the
ROM's vendor_boot.img. They only load when every vmlinux symbol they import
has exactly the CRC that our kernel exports. A mismatch means: black screen,
no touch, bootloop.

Usage:
  check_modversions.py --symvers out/Module.symvers --vendor-boot vendor_boot.img
  check_modversions.py --symvers out/Module.symvers --modules a.ko b.ko ...

Exit code 0 = all CRCs match, 1 = mismatch, 2 = usage/parse error.
"""

import argparse
import gzip
import struct
import sys

VENDOR_BOOT_MAGIC = b"VNDRBOOT"
MODVERSION_ENTRY = 64  # struct modversion_info: unsigned long crc + char name[56]


def align(value, page):
    return (value + page - 1) // page * page


def vendor_ramdisk(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != VENDOR_BOOT_MAGIC:
        raise ValueError(f"{path}: not a vendor_boot image")
    header_version, page_size = struct.unpack_from("<II", data, 8)
    ramdisk_size = struct.unpack_from("<I", data, 24)[0]
    header_size = struct.unpack_from("<I", data, 2096)[0]
    if header_version not in (3, 4):
        raise ValueError(f"unsupported vendor_boot header v{header_version}")
    offset = align(header_size, page_size)
    blob = data[offset:offset + ramdisk_size]
    if blob[:2] == b"\x1f\x8b":
        return gzip.decompress(blob)
    if blob[:6] in (b"070701", b"070702"):
        return blob
    raise ValueError("vendor ramdisk is not gzip/cpio (lz4 not supported here)")


def cpio_files(blob):
    pos = 0
    while pos + 110 <= len(blob):
        if blob[pos:pos + 6] not in (b"070701", b"070702"):
            raise ValueError(f"bad cpio magic at {pos}")
        fields = [int(blob[pos + 6 + i * 8:pos + 14 + i * 8], 16) for i in range(13)]
        filesize, namesize = fields[6], fields[11]
        name_start = pos + 110
        name = blob[name_start:name_start + namesize - 1].decode("utf-8", "replace")
        data_start = align(name_start + namesize, 4)
        if name == "TRAILER!!!":
            return
        yield name, blob[data_start:data_start + filesize]
        pos = align(data_start + filesize, 4)


def elf_section(blob, wanted):
    if blob[:4] != b"\x7fELF" or blob[4] != 2:
        raise ValueError("not a 64-bit ELF")
    e_shoff = struct.unpack_from("<Q", blob, 0x28)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", blob, 0x3A)

    def header(i):
        return struct.unpack_from("<IIQQQQIIQQ", blob, e_shoff + i * e_shentsize)

    strtab = header(e_shstrndx)
    for i in range(e_shnum):
        sh = header(i)
        name_off = strtab[4] + sh[0]
        name = blob[name_off:blob.index(b"\0", name_off)].decode()
        if name == wanted:
            return blob[sh[4]:sh[4] + sh[5]]
    return None


def module_imports(blob):
    section = elf_section(blob, "__versions")
    if section is None:
        return {}
    imports = {}
    for off in range(0, len(section), MODVERSION_ENTRY):
        crc = struct.unpack_from("<Q", section, off)[0] & 0xFFFFFFFF
        raw = section[off + 8:off + MODVERSION_ENTRY]
        imports[raw.split(b"\0", 1)[0].decode()] = crc
    return imports


def read_symvers(path):
    exports = {}
    with open(path) as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) >= 3 and "vmlinux" in cols[2:4]:
                exports[cols[1]] = int(cols[0], 16)
    return exports


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--symvers", required=True, help="Module.symvers from the kernel build")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--vendor-boot", help="vendor_boot.img of the ROM build")
    src.add_argument("--modules", nargs="+", help=".ko files to check")
    args = ap.parse_args()

    try:
        exports = read_symvers(args.symvers)
        if not exports:
            raise ValueError(f"{args.symvers}: no vmlinux exports found")
        if args.vendor_boot:
            modules = [(n, d) for n, d in cpio_files(vendor_ramdisk(args.vendor_boot)) if n.endswith(".ko")]
        else:
            modules = []
            for path in args.modules:
                with open(path, "rb") as f:
                    modules.append((path, f.read()))
    except (OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    if not modules:
        print("error: no kernel modules found", file=sys.stderr)
        return 2

    checked = 0
    mismatches = []
    for name, blob in modules:
        for symbol, crc in module_imports(blob).items():
            # Symbols exported by other vendor modules are not in vmlinux; skip them.
            if symbol not in exports:
                continue
            checked += 1
            if exports[symbol] != crc:
                mismatches.append((name, symbol, crc, exports[symbol]))

    print(f"{len(modules)} modules, {checked} vmlinux symbol imports checked")
    for name, symbol, want, have in mismatches:
        print(f"MISMATCH {name}: {symbol} module=0x{want:08x} kernel=0x{have:08x}")
    if mismatches:
        print("FAIL: this kernel is not ABI-compatible with the ROM's vendor modules")
        return 1
    print("OK: all module CRCs match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
