#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build the Hikvision-compatible SPI CramFS used for Debian boot.

The factory image places a CramFS at SPI offset 0x000a0000.  Keep the
bootloader and its environment below that offset intact, and replace only the
CramFS payload with three files loaded by the persistent boot command.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEBIAN = ROOT / "debian"
TFTP = Path(os.environ.get("TFTP_DIR", "/srv/tftp"))
OUT = Path(
    os.environ.get("SPI_CRAMFS_OUT", str(DEBIAN / "out" / "spi-cramfs"))
)

SPI_SIZE = 0x01000000
SPI_CRAMFS_OFFSET = 0x000A0000
ERASE_SIZE = 0x00010000
SPI_CRAMFS_REGION_SIZE = int(
    os.environ.get("SPI_CRAMFS_REGION_SIZE", "0x00400000"), 0
)

SOURCES = {
    "uImage": Path(
        os.environ.get(
            "SPI_CRAMFS_UIMAGE",
            str(TFTP / "uImage-hi3536dv100-k75-debian-4.9.37"),
        )
    ),
    "initrd": Path(
        os.environ.get(
            "SPI_CRAMFS_INITRD",
            str(TFTP / "initramfs-hi3536dv100-k75-debian.cpio.gz"),
        )
    ),
    "vboot": Path(
        os.environ.get(
            "SPI_CRAMFS_VBOOT", str(TFTP / "version-bootm-patch.bin")
        )
    ),
}

BOOTCMD = (
    "cramfsload 0x84000000 initrd;"
    "cramfsload 0x82000000 uImage;"
    "cramfsload 0x8dc33e20 vboot;"
    "version 0x82000000"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def main() -> None:
    mkfs = shutil.which("mkfs.cramfs")
    if mkfs is None:
        raise SystemExit("mkfs.cramfs is required")
    fakeroot = shutil.which("fakeroot")
    if fakeroot is None:
        raise SystemExit("fakeroot is required")

    missing = [str(path) for path in SOURCES.values() if not path.is_file()]
    if missing:
        raise SystemExit("missing input files: " + ", ".join(missing))

    OUT.mkdir(parents=True, exist_ok=True)
    cramfs = OUT / "digicap-debian-boot.cramfs"
    padded = OUT / "digicap-debian-boot.cramfs.padded.bin"
    manifest = OUT / "SPI_CRAMFS_LAYOUT.txt"
    existing = [path for path in (cramfs, padded, manifest) if path.exists()]
    if existing:
        raise SystemExit(
            "refusing to overwrite existing output: "
            + ", ".join(str(path) for path in existing)
        )

    with tempfile.TemporaryDirectory(prefix="digicap-spi-cramfs-") as tmp:
        tree = Path(tmp)
        for name, source in SOURCES.items():
            destination = tree / name
            shutil.copyfile(source, destination)
            destination.chmod(0o644)

        subprocess.run(
            [
                fakeroot,
                "--",
                mkfs,
                "-E",
                "-b",
                "4096",
                "-N",
                "little",
                "-n",
                "DIGICAP_BOOT",
                str(tree),
                str(cramfs),
            ],
            check=True,
        )

    image = cramfs.read_bytes()
    minimum_padded_size = align_up(len(image), ERASE_SIZE)
    padded_size = SPI_CRAMFS_REGION_SIZE
    if padded_size % ERASE_SIZE:
        raise SystemExit("SPI CramFS region size is not erase-block aligned")
    if minimum_padded_size > padded_size:
        raise SystemExit("CramFS does not fit in the configured SPI CramFS region")
    if SPI_CRAMFS_OFFSET + padded_size > SPI_SIZE:
        raise SystemExit("CramFS does not fit in the 16 MiB SPI NOR")

    padded.write_bytes(image + b"\xff" * (padded_size - len(image)))
    cramfs.chmod(0o444)
    padded.chmod(0o444)

    lines = [
        "Hikvision K75 Debian SPI CramFS",
        f"SPI_SIZE=0x{SPI_SIZE:x}",
        f"SPI_CRAMFS_OFFSET=0x{SPI_CRAMFS_OFFSET:x}",
        f"SPI_ERASE_SIZE=0x{ERASE_SIZE:x}",
        f"SPI_CRAMFS_REGION_SIZE=0x{SPI_CRAMFS_REGION_SIZE:x}",
        f"CRAMFS_SIZE=0x{len(image):x}",
        f"ERASE_WRITE_LENGTH=0x{padded_size:x}",
        f"CRAMFS_SHA256={sha256(cramfs)}",
        f"PADDED_SHA256={sha256(padded)}",
        f"BOOTCMD={BOOTCMD}",
        "",
        "Files:",
    ]
    for name, source in SOURCES.items():
        lines.append(
            f"{name} size=0x{source.stat().st_size:x} sha256={sha256(source)}"
        )
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    manifest.chmod(0o444)

    print(manifest.read_text(encoding="utf-8"), end="")


if __name__ == "__main__":
    main()
