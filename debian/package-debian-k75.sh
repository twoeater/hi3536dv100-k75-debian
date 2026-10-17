#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out_dir=${OUT_DIR:-"$script_dir/out/boot"}
kernel_src=${KERNEL_ZIMAGE:-"$script_dir/build/linux-4.9.37-hi3536dv100-k75/arch/arm/boot/zImage"}
base_dtb=${BASE_DTB:-"$out_dir/k75.dtb"}
initramfs=${INITRAMFS:-"$out_dir/initramfs-debian.cpio.gz"}
bootargs=${BOOTARGS:-'mem=256M console=ttyAMA0,115200n8 earlyprintk loglevel=8 ignore_loglevel digicap.root_transport=sata'}
artifact_suffix=${ARTIFACT_SUFFIX:-}
sata_phy_mode=${SATA_PHY_MODE:-1}

if [[ ! "$artifact_suffix" =~ ^(-[a-z0-9][a-z0-9-]*)?$ ]]; then
    printf 'ARTIFACT_SUFFIX 형식이 올바르지 않습니다: %s\n' "$artifact_suffix" >&2
    exit 2
fi

if [[ -n "$sata_phy_mode" && "$sata_phy_mode" != 0 && "$sata_phy_mode" != 1 ]]; then
    printf 'SATA_PHY_MODE 값은 0(1.5Gbps) 또는 1(3.0Gbps)이어야 합니다: %s\n' \
        "$sata_phy_mode" >&2
    exit 2
fi

for command_name in fdtget fdtput mkimage python3 sha256sum stat; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    }
done

for input_file in "$kernel_src" "$base_dtb" "$initramfs"; do
    [[ -f "$input_file" ]] || {
        printf '입력 파일을 찾을 수 없습니다: %s\n' "$input_file" >&2
        exit 1
    }
done

mkdir -p "$out_dir"
dtb="$out_dir/k75-debian-boot${artifact_suffix}.dtb"
payload="$out_dir/kernel-debian-k75${artifact_suffix}.bin"
uimage="$out_dir/uImage-debian-k75${artifact_suffix}"
cp "$base_dtb" "$dtb"

# U-Boot가 appended DTB에 initramfs 정보를 전달하지 않으므로 raw cpio.gz를
# 고정 주소에 올리고 그 범위를 DTB에 직접 기록한다.
initrd_start=$((0x84000000))
initrd_size=$(stat -c '%s' "$initramfs")
initrd_end=$((initrd_start + initrd_size))
printf -v initrd_start_hex '0x%08x' "$initrd_start"
printf -v initrd_end_hex '0x%08x' "$initrd_end"

fdtput -p -t s "$dtb" /chosen bootargs "$bootargs"
fdtput -p -t s "$dtb" /chosen stdout-path 'serial0:115200n8'
fdtput -p -t x "$dtb" /chosen linux,initrd-start "$initrd_start_hex"
fdtput -p -t x "$dtb" /chosen linux,initrd-end "$initrd_end_hex"

if [[ -n "$sata_phy_mode" ]]; then
    fdtput -t x "$dtb" /soc/phy@10030000 hisilicon,phy-mode "$sata_phy_mode"
fi

# 추출한 Hikvision DTB는 별도 syscon-reboot 노드를 사용하지만 이 커널은
# CONFIG_POWER_RESET_HISI=y, CONFIG_POWER_RESET_SYSCON=n 구성이다. OpenIPC의
# hi3536dv100.dtsi와 같이 sysctrl 노드를 hisi-reboot에 직접 연결한다.
fdtput -t s "$dtb" /soc/system-controller@12050000 compatible \
    'hisilicon,sysctrl' 'syscon'
fdtput -t x "$dtb" /soc/system-controller@12050000 reboot-offset 4

# SP804는 일반 platform driver보다 먼저 초기화된다. CRG/sysctrl 대신 OpenIPC
# 기본 DT와 같은 fixed-clock을 연결해야 부팅 초기에 시스템 tick이 생긴다.
fdtput -c "$dtb" /soc/clk_3m
fdtput -t s "$dtb" /soc/clk_3m compatible fixed-clock
fdtput -t x "$dtb" /soc/clk_3m '#clock-cells' 0
fdtput -t x "$dtb" /soc/clk_3m clock-frequency 2dc6c0
fdtput -t x "$dtb" /soc/clk_3m phandle 9
fdtput -t x "$dtb" /soc/clk_3m linux,phandle 9

fdtput -c "$dtb" /soc/clk_apb
fdtput -t s "$dtb" /soc/clk_apb compatible fixed-clock
fdtput -t x "$dtb" /soc/clk_apb '#clock-cells' 0
fdtput -t x "$dtb" /soc/clk_apb clock-frequency 2faf080
fdtput -t x "$dtb" /soc/clk_apb phandle a
fdtput -t x "$dtb" /soc/clk_apb linux,phandle a

for timer in 12000000 12010000 12020000 12030000; do
    fdtput -t x "$dtb" "/soc/amba/dual_timer@$timer" clocks 9 9 a
done
fdtput -t s "$dtb" /soc/amba/dual_timer@12000000 clock-names timer00 timer01 apb_pclk
fdtput -t s "$dtb" /soc/amba/dual_timer@12010000 clock-names timer10 timer11 apb_pclk
fdtput -t s "$dtb" /soc/amba/dual_timer@12020000 clock-names timer20 timer21 apb_pclk
fdtput -t s "$dtb" /soc/amba/dual_timer@12030000 clock-names timer30 timer31 apb_pclk

cat "$kernel_src" "$dtb" > "$payload"
mkimage -A arm -O linux -T kernel -C none \
    -a 0x80008000 -e 0x80008000 \
    -n "Linux-4.9.37-Debian-K75${artifact_suffix}" \
    -d "$payload" "$uimage" >/dev/null

# Live U-Boot의 `version` 명령 엔트리를 RAM에서 do_bootm으로 바꾸는 12바이트
# 패치다. maxargs=4, repeatable=1, handler=0x8dc12360. 전원 재인가 시 사라진다.
python3 - "$out_dir/version-bootm-patch.bin" <<'PY'
import pathlib
import struct
import sys

pathlib.Path(sys.argv[1]).write_bytes(struct.pack('<III', 4, 1, 0x8dc12360))
PY

python3 - "$uimage" <<'PY'
import pathlib
import struct
import sys
import zlib

image = pathlib.Path(sys.argv[1]).read_bytes()
magic, hcrc, _, size, load, entry, dcrc = struct.unpack('>7I', image[:28])
header = bytearray(image[:64])
header[4:8] = b'\0' * 4
payload = image[64:64 + size]
zimage_size = struct.unpack_from('<I', payload, 0x2c)[0]

assert magic == 0x27051956
assert load == entry == 0x80008000
assert len(payload) == size
assert zlib.crc32(header) & 0xffffffff == hcrc
assert zlib.crc32(payload) & 0xffffffff == dcrc
assert payload[zimage_size:zimage_size + 4] == bytes.fromhex('d00dfeed')
PY

if [[ -z "$artifact_suffix" ]]; then
    checksum_file=DEBIAN_BOOT_SHA256SUMS
else
    checksum_file="DEBIAN_BOOT${artifact_suffix}_SHA256SUMS"
fi

{
    printf '%s  %s\n' \
        "$(sha256sum "$uimage" | awk '{print $1}')" \
        "$(basename "$uimage")"
    printf '%s  %s\n' \
        "$(sha256sum "$initramfs" | awk '{print $1}')" \
        "$(basename "$initramfs")"
    printf '%s  %s\n' \
        "$(sha256sum "$out_dir/version-bootm-patch.bin" | awk '{print $1}')" \
        version-bootm-patch.bin
} > "$out_dir/$checksum_file"

printf '생성 완료: %s\n' "$uimage"
printf 'raw initramfs 주소: %s-%s (%d bytes)\n' \
    "$initrd_start_hex" "$initrd_end_hex" "$initrd_size"
cat "$out_dir/$checksum_file"
