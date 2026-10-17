#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rootfs_tar=${ROOTFS_TAR:-"$script_dir/out/debian-bookworm-armhf-rootfs.tar.gz"}
out_dir=${OUT_DIR:-"$script_dir/out/msata-image"}
image_size_mib=${IMAGE_SIZE_MIB:-2048}
swap_mb=${SWAP_MB:-512}
filesystem_uuid_request=${FILESYSTEM_UUID:-}
image="$out_dir/digicap-debian-msata-rootfs.ext4"
compressed_image="$image.gz"

for command_name in blkid e2fsck fallocate gzip mkfs.ext4 mountpoint mkswap \
    sha256sum stat tar truncate; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    }
done

[[ "$image_size_mib" =~ ^[0-9]+$ ]] && (( image_size_mib >= 1024 )) || {
    printf 'IMAGE_SIZE_MIB는 1024 이상의 정수여야 합니다: %s\n' \
        "$image_size_mib" >&2
    exit 2
}
[[ "$swap_mb" =~ ^[0-9]+$ ]] || {
    printf 'SWAP_MB는 0 이상의 정수여야 합니다: %s\n' "$swap_mb" >&2
    exit 2
}
[[ -f "$rootfs_tar" ]] || {
    printf 'rootfs tar를 찾을 수 없습니다: %s\n' "$rootfs_tar" >&2
    exit 1
}

mkdir -p "$out_dir"
for output_file in "$image" "$compressed_image"; do
    [[ ! -e "$output_file" ]] || {
        printf '기존 산출물을 덮어쓰지 않습니다: %s\n' "$output_file" >&2
        exit 1
    }
done

work_dir=$(mktemp -d)
mount_dir="$work_dir/root"
mkdir "$mount_dir"

cleanup()
{
    if mountpoint -q "$mount_dir"; then
        sudo umount "$mount_dir" || true
    fi
    rmdir "$mount_dir" 2>/dev/null || true
    rmdir "$work_dir" 2>/dev/null || true
}
trap cleanup EXIT

truncate -s "${image_size_mib}M" "$image"
mkfs_uuid_options=()
if [[ -n "$filesystem_uuid_request" ]]; then
    mkfs_uuid_options=(-U "$filesystem_uuid_request")
fi
mkfs.ext4 -F \
    -L DIGICAP_MSATA \
    "${mkfs_uuid_options[@]}" \
    -m 1 \
    -O '^64bit,^metadata_csum,^orphan_file' \
    -E lazy_itable_init=0,lazy_journal_init=0 \
    "$image" >/dev/null

filesystem_uuid=$(blkid -p -s UUID -o value "$image")
[[ -n "$filesystem_uuid" ]] || {
    printf '생성한 ext4 이미지의 UUID를 읽지 못했습니다: %s\n' "$image" >&2
    exit 1
}

sudo mount -o loop,rw "$image" "$mount_dir"
sudo tar --numeric-owner --xattrs --acls -xpf "$rootfs_tar" -C "$mount_dir"

{
    printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$filesystem_uuid"
    if (( swap_mb > 0 )); then
        printf '/swapfile none swap sw 0 0\n'
    fi
} | sudo tee "$mount_dir/etc/fstab" >/dev/null

printf '80578_P Debian rootfs\n' |
    sudo tee "$mount_dir/.digicap-debian-root" >/dev/null
sudo chown 0:0 "$mount_dir/etc/fstab" "$mount_dir/.digicap-debian-root"
sudo chmod 0644 "$mount_dir/etc/fstab" "$mount_dir/.digicap-debian-root"

if (( swap_mb > 0 )); then
    sudo fallocate -l "${swap_mb}M" "$mount_dir/swapfile"
    sudo chown 0:0 "$mount_dir/swapfile"
    sudo chmod 0600 "$mount_dir/swapfile"
    sudo mkswap -f "$mount_dir/swapfile" >/dev/null
fi

sudo test -x "$mount_dir/firstboot"
sudo test -c "$mount_dir/dev/console"
sudo test -c "$mount_dir/dev/null"
sudo stat -c '%u:%g %a %n' \
    "$mount_dir/usr/bin/passwd" \
    "$mount_dir/usr/bin/su" \
    "$mount_dir/firstboot" \
    "$mount_dir/.digicap-debian-root"

sync
sudo umount "$mount_dir"
e2fsck -fn "$image"

gzip -1n -c "$image" > "$compressed_image"
(
    cd "$out_dir"
    sha256sum "$(basename "$image")" "$(basename "$compressed_image")" \
        > digicap-debian-msata-rootfs.sha256
)

printf '생성 완료: %s\n' "$compressed_image"
printf '파일시스템 UUID: %s\n' "$filesystem_uuid"
stat -c '%n %s bytes' "$image" "$compressed_image"
cat "$out_dir/digicap-debian-msata-rootfs.sha256"
