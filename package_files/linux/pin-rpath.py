#!/usr/bin/env python3
"""Refile the bundled HDF libraries' search path from DT_RUNPATH to DT_RPATH.

The loader consults DT_RUNPATH after LD_LIBRARY_PATH and DT_RPATH before it.
This script only changes the tag changes.

Usage: pin-rpath.py <jpackage-dest-dir>

Runs on every platform during app-image creation, acts only on the Linux layout.
Exits 0 when every bundled library that depends on a sibling carries an $ORIGIN-relative DT_RPATH.
"""

import struct
import sys
from pathlib import Path

DT_NULL = 0x00
DT_RPATH = 0x0F
DT_RUNPATH = 0x1D

SHT_DYNAMIC = 6

# Wrappers that a complete bundle must carry
EXPECTED = ("libhdf5_java.so", "libhdf_java.so")

# Libraries whose dependencies we bundle, which must end up with DT_RPATH
MUST_BE_PINNED = EXPECTED + ("libmfhdf.so", "libhdf5_hl.so", "libhdf5_tools.so")

CONVERT_GLOBS = ("libhdf*.so*", "libmfhdf*.so*", "libdf*.so*")


class ElfError(Exception):
    """The file is not an ELF64 shared object."""


def _dynamic(data):
    """Return ([(file_position, tag, value)], dynstr_offset).

    dynstr_offset is where DT_RPATH/DT_RUNPATH values index from, via the
    .dynamic section's sh_link.
    """
    if data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2:
        raise ElfError("not 64-bit")
    if data[5] != 1:
        raise ElfError("not little-endian")

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
    if not e_shoff or not e_shnum:
        raise ElfError("no section headers")

    for i in range(e_shnum):
        sh = e_shoff + i * e_shentsize
        if struct.unpack_from("<I", data, sh + 4)[0] != SHT_DYNAMIC:
            continue

        dyn_offset, dyn_size = struct.unpack_from("<QQ", data, sh + 0x18)
        strtab_index = struct.unpack_from("<I", data, sh + 0x28)[0]
        strtab_sh = e_shoff + strtab_index * e_shentsize
        dynstr_offset = struct.unpack_from("<Q", data, strtab_sh + 0x18)[0]

        entries = []
        for pos in range(dyn_offset, dyn_offset + dyn_size, 16):
            tag, value = struct.unpack_from("<QQ", data, pos)
            if tag == DT_NULL:
                break
            entries.append((pos, tag, value))
        return entries, dynstr_offset

    raise ElfError("no .dynamic section")


def _string_at(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", "replace")


def search_path(path):
    """Return (tag, path_string) for the library's DT_RPATH/DT_RUNPATH, or None."""
    data = path.read_bytes()
    entries, dynstr = _dynamic(data)
    for _, tag, value in entries:
        if tag in (DT_RPATH, DT_RUNPATH):
            return tag, _string_at(data, dynstr + value)
    return None


def is_relocatable(value):
    """True if every component of a search path is $ORIGIN-relative."""
    components = [c for c in value.split(":") if c]
    return bool(components) and all(c.startswith("$ORIGIN") for c in components)


def convert(path):
    """Rewrite DT_RUNPATH as DT_RPATH. Returns True if the file was changed."""
    data = bytearray(path.read_bytes())
    entries, _ = _dynamic(data)
    positions = [pos for pos, tag, _ in entries if tag == DT_RUNPATH]
    if not positions:
        return False
    for pos in positions:
        struct.pack_into("<Q", data, pos, DT_RPATH)
    path.write_bytes(data)
    return True


def locate_linux_appdir(dest):
    """Return the Linux app-image's native library directory under dest.

    None for a Windows or macOS app-image. Raises LookupError if dest holds
    nothing recognisable.
    """
    # jdk.jpackage ApplicationLayout: APP is lib/app on Linux, app on Windows,
    # Contents/app on macOS.
    for image in sorted(dest.iterdir()):
        if not image.is_dir():
            continue
        if (image / "lib" / "app").is_dir():
            return image / "lib" / "app"
        if (image / "Contents" / "app").is_dir():
            return None  # macOS: @rpath/@loader_path already resolve correctly
        if (image / "app").is_dir():
            return None  # Windows: handled by relocate-core-dlls.ps1
    raise LookupError(f"no jpackage app-image found under {dest}")


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    dest = Path(argv[1])
    if not dest.is_dir():
        print(f"error: {dest} is not a directory", file=sys.stderr)
        return 2

    try:
        appdir = locate_linux_appdir(dest)
    except LookupError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if appdir is None:
        print("  not a Linux app-image")
        return 0

    candidates = sorted(
        {p for glob in CONVERT_GLOBS for p in appdir.glob(glob) if p.is_file()}
    )

    if not candidates:
        print(f"error: no HDF libraries found in {appdir}", file=sys.stderr)
        return 1

    failures = []

    for expected in EXPECTED:
        if not any(p.name.startswith(expected) for p in candidates):
            print(f"  warning: {expected}* is not in this bundle")

    for lib in candidates:
        try:
            found = search_path(lib)
        except ElfError as exc:
            failures.append(f"{lib.name}: {exc}")
            continue

        # Refuse to raise the priority of a path that would point outside the bundle
        if found is not None:
            _, value = found
            if not is_relocatable(value):
                failures.append(f"{lib.name}: search path is not $ORIGIN-relative: {value}")
                continue

        if convert(lib):
            print(f"  pinned {lib.name}")

    for lib in candidates:
        if not lib.name.startswith(MUST_BE_PINNED):
            continue
        try:
            found = search_path(lib)
        except ElfError:
            continue
        if found is None:
            failures.append(f"{lib.name} has no DT_RPATH or DT_RUNPATH at all")
            continue
        tag, value = found
        if tag != DT_RPATH:
            failures.append(f"{lib.name} still carries DT_RUNPATH")
        elif not is_relocatable(value):
            failures.append(f"{lib.name} has a non-relocatable DT_RPATH: {value}")

    if failures:
        _report(failures)
        return 1

    print(f"OK: {len(candidates)} bundled HDF libraries pinned to $ORIGIN")
    return 0


def _report(failures):
    print("\nERROR: bundled libraries are not pinned:", file=sys.stderr)
    for line in failures:
        print(f"  {line}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
