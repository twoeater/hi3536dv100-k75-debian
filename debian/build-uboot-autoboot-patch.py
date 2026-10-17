#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Patch the K75 U-Boot vendor default command to ``run debian``.

The Hikvision vendor initialization overwrites the persistent ``default``
environment variable on every boot.  Its replacement string lives in the
SPI NOR sector at 0x00040000.  This script accepts a freshly read 64 KiB
sector, validates the exact factory bytes, and changes only that fixed-size
string field.  The adjacent ``default`` variable name remains untouched.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path


SPI_SECTOR_OFFSET = 0x00040000
SPI_SECTOR_SIZE = 0x00010000
COMMAND_LOCAL_OFFSET = 0x000054CC
OLD_COMMAND = b"cramfsload 0x82000000 uImage;"
NEW_COMMAND = b"run debian"
FOLLOWING_BYTES = b"\0default\0verify\0"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "source",
        type=Path,
        help="64 KiB sector read directly from SPI offset 0x00040000",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "out" / "uboot-autoboot",
    )
    parser.add_argument(
        "--tftp-dir",
        type=Path,
        default=Path("/srv/tftp"),
    )
    args = parser.parse_args()

    source = args.source.resolve()
    original = source.read_bytes()
    if len(original) != SPI_SECTOR_SIZE:
        raise SystemExit(
            f"refusing input of {len(original)} bytes; expected {SPI_SECTOR_SIZE}"
        )

    start = COMMAND_LOCAL_OFFSET
    end = start + len(OLD_COMMAND)
    expected = OLD_COMMAND + FOLLOWING_BYTES
    actual = original[start : start + len(expected)]
    if actual != expected:
        raise SystemExit(
            "refusing unexpected U-Boot bytes at "
            f"SPI 0x{SPI_SECTOR_OFFSET + start:08x}: {actual!r}"
        )
    if original.count(OLD_COMMAND) != 1:
        raise SystemExit("refusing sector without exactly one target command")
    if len(NEW_COMMAND) > len(OLD_COMMAND):
        raise SystemExit("replacement command does not fit the fixed string field")

    patched = bytearray(original)
    patched[start:end] = NEW_COMMAND + b"\0" * (
        len(OLD_COMMAND) - len(NEW_COMMAND)
    )
    patched = bytes(patched)

    if patched[start : start + len(NEW_COMMAND) + 1] != NEW_COMMAND + b"\0":
        raise SystemExit("replacement command validation failed")
    name_offset = start + len(OLD_COMMAND) + 1
    if patched[name_offset : name_offset + 8] != b"default\0":
        raise SystemExit("adjacent default variable name was modified")

    differences = [
        index for index, (before, after) in enumerate(zip(original, patched))
        if before != after
    ]
    if not differences or min(differences) < start or max(differences) >= end:
        raise SystemExit("changes escaped the fixed command field")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    original_path = args.output_dir / "uboot-sector-40000-original.bin"
    patched_path = args.output_dir / "uboot-sector-40000-run-debian.bin"
    manifest_path = args.output_dir / "UBOOT_AUTOBOOT_PATCH.txt"

    original_path.write_bytes(original)
    patched_path.write_bytes(patched)
    for path in (original_path, patched_path):
        path.chmod(0o444)

    manifest = "\n".join(
        [
            "Hikvision K75 U-Boot automatic Debian boot patch",
            f"SOURCE={source}",
            f"SPI_OFFSET=0x{SPI_SECTOR_OFFSET:08x}",
            f"SPI_LENGTH=0x{SPI_SECTOR_SIZE:08x}",
            f"COMMAND_OFFSET=0x{SPI_SECTOR_OFFSET + start:08x}",
            f"OLD_COMMAND={OLD_COMMAND.decode()}",
            f"NEW_COMMAND={NEW_COMMAND.decode()}",
            f"ORIGINAL_SHA256={sha256(original)}",
            f"PATCHED_SHA256={sha256(patched)}",
            f"CHANGED_BYTE_COUNT={len(differences)}",
            f"FIRST_CHANGED_OFFSET=0x{SPI_SECTOR_OFFSET + min(differences):08x}",
            f"LAST_CHANGED_OFFSET=0x{SPI_SECTOR_OFFSET + max(differences):08x}",
            "",
        ]
    )
    manifest_path.write_text(manifest, encoding="utf-8")
    manifest_path.chmod(0o444)

    args.tftp_dir.mkdir(parents=True, exist_ok=True)
    tftp_path = args.tftp_dir / patched_path.name
    shutil.copyfile(patched_path, tftp_path)
    tftp_path.chmod(0o444)

    print(manifest, end="")
    print(f"TFTP_FILE={tftp_path}")


if __name__ == "__main__":
    main()
