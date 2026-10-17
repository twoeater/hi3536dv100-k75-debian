#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kernel_dir=${KERNEL_DIR:-"$script_dir/build/linux-4.9.37-hi3536dv100-k75"}
fragment=${KERNEL_CONFIG_FRAGMENT:-"$script_dir/kernel-configs/docker-bridge.config"}
cross_compile=${CROSS_COMPILE:-arm-linux-gnueabi-}
jobs=${JOBS:-$(nproc)}
out_dir=${OUT_DIR:-"$script_dir/out/boot-docker-bridge"}
spi_out_dir=${SPI_OUT_DIR:-"$script_dir/out/spi-cramfs-docker-bridge"}
base_dtb=${BASE_DTB:-"$script_dir/out/boot/k75.dtb"}
rootfs_tar=${ROOTFS_TAR:-"$script_dir/out/debian-bookworm-armhf-rootfs.tar.gz"}
artifact_suffix=${ARTIFACT_SUFFIX:--docker-bridge}

for command_name in make nproc python3 "${cross_compile}gcc"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    fi
done

for input_file in \
    "$kernel_dir/.config" \
    "$kernel_dir/scripts/kconfig/merge_config.sh" \
    "$fragment" \
    "$base_dtb" \
    "$rootfs_tar"; do
    if [[ ! -f "$input_file" ]]; then
        printf '입력 파일을 찾을 수 없습니다: %s\n' "$input_file" >&2
        exit 1
    fi
done

if [[ -e "$spi_out_dir/digicap-debian-boot.cramfs" ||
      -e "$spi_out_dir/digicap-debian-boot.cramfs.padded.bin" ||
      -e "$spi_out_dir/SPI_CRAMFS_LAYOUT.txt" ]]; then
    printf '기존 SPI 출력 디렉터리를 덮어쓰지 않습니다: %s\n' "$spi_out_dir" >&2
    exit 2
fi

# Preserve the prepared configuration before re-merging and validating the
# container fragment. Re-running this script does not replace that backup.
if [[ ! -e "$kernel_dir/.config.before-docker-bridge" ]]; then
    cp -p "$kernel_dir/.config" "$kernel_dir/.config.before-docker-bridge"
fi

(
    cd "$kernel_dir"
    ARCH=arm scripts/kconfig/merge_config.sh -m .config "$fragment"
    make ARCH=arm CROSS_COMPILE="$cross_compile" olddefconfig
)

# Fail if Kconfig silently dropped or changed any requested option.
while IFS= read -r requested; do
    if ! grep -Fqx "$requested" "$kernel_dir/.config"; then
        printf '커널 설정에 반영되지 않은 항목: %s\n' "$requested" >&2
        exit 1
    fi
done < <(grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' "$fragment")

make -C "$kernel_dir" -j"$jobs" \
    ARCH=arm CROSS_COMPILE="$cross_compile" zImage modules

OUT_DIR="$out_dir" \
ROOTFS_TAR="$rootfs_tar" \
STOCK_KERNEL_DIR="$kernel_dir" \
    "$script_dir/build-initramfs.sh"

OUT_DIR="$out_dir" \
KERNEL_ZIMAGE="$kernel_dir/arch/arm/boot/zImage" \
BASE_DTB="$base_dtb" \
INITRAMFS="$out_dir/initramfs-debian.cpio.gz" \
ARTIFACT_SUFFIX="$artifact_suffix" \
SATA_PHY_MODE=1 \
    "$script_dir/package-debian-k75.sh"

SPI_CRAMFS_OUT="$spi_out_dir" \
SPI_CRAMFS_UIMAGE="$out_dir/uImage-debian-k75${artifact_suffix}" \
SPI_CRAMFS_INITRD="$out_dir/initramfs-debian.cpio.gz" \
SPI_CRAMFS_VBOOT="$out_dir/version-bootm-patch.bin" \
    python3 "$script_dir/build-spi-cramfs.py"

printf '\nDocker/bridge 부팅 이미지 생성 완료\n'
printf 'uImage: %s\n' "$out_dir/uImage-debian-k75${artifact_suffix}"
printf 'initramfs: %s\n' "$out_dir/initramfs-debian.cpio.gz"
printf 'SPI CramFS: %s\n' \
    "$spi_out_dir/digicap-debian-boot.cramfs.padded.bin"
