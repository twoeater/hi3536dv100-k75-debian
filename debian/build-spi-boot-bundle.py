#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
import hashlib
import pathlib
import sys


SPI_KERNEL_OFFSET = 0x100000
SPI_INITRAMFS_OFFSET = 0x500000
SPI_PATCH_OFFSET = 0x620000
ERASE_SIZE = 0x10000
KERNEL_LIMIT = SPI_INITRAMFS_OFFSET - SPI_KERNEL_OFFSET


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    project_dir = pathlib.Path(__file__).resolve().parent.parent
    tftp_dir = pathlib.Path("/srv/tftp")
    out_dir = project_dir / "debian" / "out" / "spi-boot"
    kernel_path = tftp_dir / "uImage-debian-k75-msata-root"
    initramfs_path = tftp_dir / "initramfs-debian-msata-root.cpio.gz"
    patch_path = tftp_dir / "version-bootm-patch.bin"

    for input_path in (kernel_path, initramfs_path, patch_path):
        if not input_path.is_file():
            print(f"입력 파일을 찾을 수 없습니다: {input_path}", file=sys.stderr)
            return 1

    kernel = kernel_path.read_bytes()
    initramfs = initramfs_path.read_bytes()
    command_patch = patch_path.read_bytes()

    if len(kernel) > KERNEL_LIMIT:
        print("커널이 4MiB SPI 영역보다 큽니다.", file=sys.stderr)
        return 1
    if len(command_patch) != 12:
        print("version 명령 패치는 정확히 12바이트여야 합니다.", file=sys.stderr)
        return 1
    initramfs_limit = SPI_PATCH_OFFSET - SPI_INITRAMFS_OFFSET
    if len(initramfs) > initramfs_limit:
        print("initramfs가 예약된 SPI 영역보다 큽니다.", file=sys.stderr)
        return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    kernel_bundle_path = out_dir / "spi-kernel.bin"
    boot_bundle_path = out_dir / "spi-initramfs-and-patch.bin"
    manifest_path = out_dir / "SPI_BOOT_LAYOUT.txt"
    for output_path in (kernel_bundle_path, boot_bundle_path, manifest_path):
        if output_path.exists():
            print(f"기존 산출물을 덮어쓰지 않습니다: {output_path}", file=sys.stderr)
            return 1

    kernel_erase_size = align_up(len(kernel), ERASE_SIZE)
    kernel_bundle = kernel + bytes([0xFF]) * (kernel_erase_size - len(kernel))

    patch_relative_offset = SPI_PATCH_OFFSET - SPI_INITRAMFS_OFFSET
    boot_used_size = patch_relative_offset + len(command_patch)
    boot_erase_size = align_up(boot_used_size, ERASE_SIZE)
    boot_bundle = bytearray([0xFF]) * boot_erase_size
    boot_bundle[: len(initramfs)] = initramfs
    boot_bundle[patch_relative_offset:boot_used_size] = command_patch

    kernel_bundle_path.write_bytes(kernel_bundle)
    boot_bundle_path.write_bytes(boot_bundle)

    bootcmd = (
        f"sf probe 0;"
        f"sf read 0x82000000 0x{SPI_KERNEL_OFFSET:x} 0x{len(kernel):x};"
        f"sf read 0x84000000 0x{SPI_INITRAMFS_OFFSET:x} 0x{len(initramfs):x};"
        f"sf read 0x8dc33e20 0x{SPI_PATCH_OFFSET:x} 0xc;"
        "version 0x82000000"
    )
    manifest = "\n".join(
        [
            "Hi3536DV100 SPI NOR Debian boot layout",
            "",
            f"kernel_offset=0x{SPI_KERNEL_OFFSET:x}",
            f"kernel_size=0x{len(kernel):x}",
            f"kernel_erase_size=0x{kernel_erase_size:x}",
            f"kernel_sha256={sha256(kernel)}",
            f"kernel_bundle_sha256={sha256(kernel_bundle)}",
            "",
            f"initramfs_offset=0x{SPI_INITRAMFS_OFFSET:x}",
            f"initramfs_size=0x{len(initramfs):x}",
            f"initramfs_sha256={sha256(initramfs)}",
            f"patch_offset=0x{SPI_PATCH_OFFSET:x}",
            f"patch_size=0x{len(command_patch):x}",
            f"patch_sha256={sha256(command_patch)}",
            f"boot_bundle_erase_size=0x{boot_erase_size:x}",
            f"boot_bundle_sha256={sha256(boot_bundle)}",
            "",
            f"bootcmd={bootcmd}",
            "",
        ]
    )
    manifest_path.write_text(manifest, encoding="utf-8")
    print(manifest, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
