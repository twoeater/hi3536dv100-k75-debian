#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf '사용법: %s ROOTFS_TAR EXT4_MOUNTPOINT\n' "$0" >&2
    exit 2
fi

rootfs_tar=$(realpath "$1")
mountpoint_path=$(realpath "$2")
swap_mb=${SWAP_MB:-512}

if [[ ! "$swap_mb" =~ ^[0-9]+$ ]]; then
    printf 'SWAP_MB는 0 이상의 정수여야 합니다: %s\n' "$swap_mb" >&2
    exit 2
fi

if [[ ! -f "$rootfs_tar" ]]; then
    printf 'rootfs tar를 찾을 수 없습니다: %s\n' "$rootfs_tar" >&2
    exit 1
fi
if ! mountpoint -q "$mountpoint_path"; then
    printf '대상은 실제 마운트 지점이어야 합니다: %s\n' "$mountpoint_path" >&2
    exit 1
fi
filesystem=$(findmnt -n -o FSTYPE --target "$mountpoint_path")
if [[ "$filesystem" != ext4 ]]; then
    printf '대상 파일시스템이 ext4가 아닙니다: %s (%s)\n' "$mountpoint_path" "$filesystem" >&2
    exit 1
fi
if find "$mountpoint_path" -mindepth 1 -maxdepth 1 -not -name lost+found -print -quit | grep -q .; then
    printf '대상 파일시스템이 비어 있지 않습니다: %s\n' "$mountpoint_path" >&2
    exit 1
fi

printf '다음 ext4 파일시스템에 Debian rootfs를 설치합니다. 기존 파일은 보존되지 않을 수 있습니다.\n'
findmnt --target "$mountpoint_path"
printf '계속하려면 마운트 지점 전체 경로를 입력하세요: '
read -r confirmation
if [[ "$confirmation" != "$mountpoint_path" ]]; then
    printf '입력이 일치하지 않아 중단합니다.\n' >&2
    exit 1
fi

sudo tar --numeric-owner --xattrs --acls -xpf "$rootfs_tar" -C "$mountpoint_path"
source_device=$(findmnt -n -o SOURCE --target "$mountpoint_path")
root_uuid=$(sudo blkid -s UUID -o value "$source_device")
if [[ -z "$root_uuid" ]]; then
    printf '대상 ext4 파일시스템의 UUID를 읽지 못했습니다: %s\n' "$source_device" >&2
    exit 1
fi

fstab_file=$(mktemp)
trap 'rm -f -- "$fstab_file"' EXIT
{
    printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$root_uuid"
    if (( swap_mb > 0 )); then
        printf '/swapfile none swap sw 0 0\n'
    fi
    printf 'proc /proc proc defaults 0 0\n'
} > "$fstab_file"
sudo install -m 0644 -o 0 -g 0 "$fstab_file" "$mountpoint_path/etc/fstab"
printf '80578_P Debian rootfs\n' | sudo tee "$mountpoint_path/.digicap-debian-root" >/dev/null
sudo chown 0:0 "$mountpoint_path/.digicap-debian-root"
sudo chmod 0644 "$mountpoint_path/.digicap-debian-root"

if (( swap_mb > 0 )); then
    printf '%s MiB swapfile을 생성합니다.\n' "$swap_mb"
    if ! sudo fallocate -l "${swap_mb}M" "$mountpoint_path/swapfile"; then
        sudo dd if=/dev/zero of="$mountpoint_path/swapfile" bs=1M count="$swap_mb" status=progress
    fi
    sudo chmod 0600 "$mountpoint_path/swapfile"
    sudo chown 0:0 "$mountpoint_path/swapfile"
    sudo mkswap -f "$mountpoint_path/swapfile" >/dev/null
fi
sync
printf '설치 완료: %s\n' "$mountpoint_path"
