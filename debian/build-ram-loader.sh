#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out_dir=${OUT_DIR:-"$script_dir/out/ram-loader"}
kernel_uimage=${KERNEL_UIMAGE:-"$script_dir/out/boot-docker-bridge/uImage-debian-k75-docker-bridge"}
stock_uimage=${STOCK_UIMAGE:-"$script_dir/out/boot/uImage-stock-signed"}
initramfs=${INITRAMFS:-"$script_dir/out/boot-docker-bridge/initramfs-debian.cpio.gz"}
base_dtb=${BASE_DTB:-"$script_dir/out/boot/k75.dtb"}
loader_src="$script_dir/ram-loader/loader.S"
loader_ld="$script_dir/ram-loader/loader.ld"

for command_name in arm-linux-gnueabi-as arm-linux-gnueabi-ld \
    arm-linux-gnueabi-objcopy arm-linux-gnueabi-objdump dumpimage \
    fdtget fdtput file python3 sha256sum stat; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    fi
done

for input_file in "$kernel_uimage" "$stock_uimage" "$initramfs" "$base_dtb" \
    "$loader_src" "$loader_ld"; do
    if [[ ! -f "$input_file" ]]; then
        printf '입력 파일을 찾을 수 없습니다: %s\n' "$input_file" >&2
        exit 1
    fi
done

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$out_dir"

dumpimage -T kernel -p 0 -o "$work_dir/zImage-k75" "$kernel_uimage" >/dev/null
if ! file "$work_dir/zImage-k75" | grep -q 'Linux kernel ARM boot executable zImage'; then
    printf '추출 결과가 ARM zImage가 아닙니다.\n' >&2
    exit 1
fi

cp "$base_dtb" "$work_dir/k75-debian.dtb"
initrd_start=$((0x84000000))
initrd_size=$(stat -c '%s' "$initramfs")
initrd_end=$((initrd_start + initrd_size))
printf -v initrd_start_hex '0x%08x' "$initrd_start"
printf -v initrd_end_hex '0x%08x' "$initrd_end"

bootargs='mem=160M console=ttyAMA0,115200n8 console=ttyS0,115200n8 loglevel=8 ignore_loglevel'
fdtput -p -t s "$work_dir/k75-debian.dtb" /chosen bootargs "$bootargs"
fdtput -p -t s "$work_dir/k75-debian.dtb" /chosen stdout-path 'serial0:115200n8'
fdtput -p -t x "$work_dir/k75-debian.dtb" /chosen linux,initrd-start "$initrd_start_hex"
fdtput -p -t x "$work_dir/k75-debian.dtb" /chosen linux,initrd-end "$initrd_end_hex"

arm-linux-gnueabi-as -mcpu=cortex-a7 -o "$work_dir/linux-loader.o" "$loader_src"
arm-linux-gnueabi-ld --build-id=none -T "$loader_ld" \
    -o "$work_dir/linux-loader.elf" "$work_dir/linux-loader.o"
arm-linux-gnueabi-objcopy -O binary "$work_dir/linux-loader.elf" \
    "$work_dir/linux-loader.bin"
arm-linux-gnueabi-objdump -d "$work_dir/linux-loader.elf" \
    > "$work_dir/linux-loader.dis"

# Hikvision bootm가 정상적인 검증/CPU 정리를 수행하게 하되, 검증 후 진입점만
# RAM 로더(0x81000000)로 향하게 한다. Legacy uImage 헤더 CRC는 다시 계산하고,
# 서명 대상일 수 있는 데이터와 파일 끝의 RSA 트레일러는 한 바이트도 바꾸지 않는다.
python3 - "$stock_uimage" "$work_dir/uImage-stock-loader-entry" <<'PY'
import pathlib
import struct
import sys
import zlib

source_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
image = bytearray(source_path.read_bytes())
if len(image) < 64 or struct.unpack_from(">I", image, 0)[0] != 0x27051956:
    raise SystemExit("stock image is not a legacy uImage")

original_after_header = bytes(image[64:])
struct.pack_into(">I", image, 20, 0x81000000)
struct.pack_into(">I", image, 4, 0)
header_crc = zlib.crc32(image[:64]) & 0xFFFFFFFF
struct.pack_into(">I", image, 4, header_crc)

if bytes(image[64:]) != original_after_header:
    raise SystemExit("payload or RSA trailer changed unexpectedly")
output_path.write_bytes(image)
PY

install -m 0644 "$work_dir/zImage-k75" "$out_dir/zImage-k75"
install -m 0644 "$work_dir/k75-debian.dtb" "$out_dir/k75-debian.dtb"
install -m 0644 "$work_dir/linux-loader.bin" "$out_dir/linux-loader.bin"
install -m 0644 "$work_dir/linux-loader.elf" "$out_dir/linux-loader.elf"
install -m 0644 "$work_dir/linux-loader.dis" "$out_dir/linux-loader.dis"
install -m 0644 "$initramfs" "$out_dir/initramfs-debian.cpio.gz"
install -m 0644 "$work_dir/uImage-stock-loader-entry" \
    "$out_dir/uImage-stock-loader-entry"

if [[ $(fdtget -t x "$out_dir/k75-debian.dtb" /chosen linux,initrd-start) != 84000000 ]]; then
    printf 'DTB initrd 시작 주소 검증에 실패했습니다.\n' >&2
    exit 1
fi
if [[ $(fdtget -t x "$out_dir/k75-debian.dtb" /chosen linux,initrd-end) != ${initrd_end_hex#0x} ]]; then
    printf 'DTB initrd 끝 주소 검증에 실패했습니다.\n' >&2
    exit 1
fi

(
    cd "$out_dir"
    sha256sum linux-loader.bin uImage-stock-loader-entry zImage-k75 \
        initramfs-debian.cpio.gz k75-debian.dtb > RAM_BOOT_SHA256SUMS
)

printf 'RAM 부팅 파일 생성 완료: %s\n' "$out_dir"
printf 'initrd: %s-%s (%d bytes)\n' \
    "$initrd_start_hex" "$initrd_end_hex" "$initrd_size"
cat "$out_dir/RAM_BOOT_SHA256SUMS"
