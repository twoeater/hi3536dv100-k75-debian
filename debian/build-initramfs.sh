#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
rootfs_tar=${ROOTFS_TAR:-"$script_dir/out/debian-bookworm-armhf-rootfs.tar.gz"}
out_dir=${OUT_DIR:-"$script_dir/out/boot"}
init_file="$script_dir/initramfs/init"
firstboot_file="$script_dir/overlay/firstboot"
stock_kernel_dir=${STOCK_KERNEL_DIR:-"$script_dir/build/linux-4.9.37-hi3536dv100-k75"}

for command_name in cpio dpkg-deb dumpimage fakeroot file gzip mkimage sha256sum tar; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    fi
done

if [[ ! -f "$rootfs_tar" ]]; then
    printf 'rootfs tar를 찾을 수 없습니다: %s\n' "$rootfs_tar" >&2
    exit 1
fi
if [[ ! -x "$init_file" ]]; then
    printf '실행 가능한 init 파일을 찾을 수 없습니다: %s\n' "$init_file" >&2
    exit 1
fi
if [[ ! -x "$firstboot_file" ]]; then
    printf '실행 가능한 firstboot 파일을 찾을 수 없습니다: %s\n' "$firstboot_file" >&2
    exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$work_dir/root/bin" "$work_dir/root/dev" "$work_dir/root/sbin" "$out_dir"

busybox_deb=${BUSYBOX_DEB:-}
if [[ -z "$busybox_deb" ]]; then
    busybox_deb=$(find "$script_dir/build" -type f -name 'busybox-static*_armhf.deb' -print -quit 2>/dev/null || true)
fi
if [[ -z "$busybox_deb" ]]; then
    busybox_member=$(tar -tzf "$rootfs_tar" | awk '/busybox-static_.*_armhf\.deb$/ { print; exit }')
    if [[ -z "$busybox_member" ]]; then
        printf 'ARMHF busybox-static 패키지를 찾지 못했습니다.\n' >&2
        exit 1
    fi
    busybox_deb="$work_dir/busybox-static_armhf.deb"
    tar -xOzf "$rootfs_tar" "$busybox_member" > "$busybox_deb"
fi

dpkg-deb -x "$busybox_deb" "$work_dir/busybox-package"
if [[ ! -x "$work_dir/busybox-package/bin/busybox" ]]; then
    printf 'busybox-static 패키지에 /bin/busybox가 없습니다.\n' >&2
    exit 1
fi
if ! file "$work_dir/busybox-package/bin/busybox" | grep -q 'ARM'; then
    printf 'busybox가 ARM 실행 파일이 아닙니다.\n' >&2
    exit 1
fi

cp "$work_dir/busybox-package/bin/busybox" "$work_dir/root/bin/busybox"
cp "$init_file" "$work_dir/root/init"
cp "$firstboot_file" "$work_dir/root/digicap-firstboot"
ln -s ../bin/busybox "$work_dir/root/sbin/mdev"
chmod 0755 "$work_dir/root/bin/busybox" "$work_dir/root/init" "$work_dir/root/digicap-firstboot"

module_dest="$work_dir/root/lib/modules/4.9.37"
module_sources=(
    "$stock_kernel_dir/fs/mbcache.ko"
    "$stock_kernel_dir/fs/jbd2/jbd2.ko"
    "$stock_kernel_dir/fs/ext4/ext4.ko"
)
module_count=0
for module_source in "${module_sources[@]}"; do
    if [[ -f "$module_source" ]]; then
        mkdir -p "$module_dest"
        cp "$module_source" "$module_dest/$(basename "$module_source")"
        module_count=$((module_count + 1))
    fi
done
if (( module_count != 0 && module_count != ${#module_sources[@]} )); then
    printf 'ext4 모듈 일부만 존재합니다. 세 모듈을 모두 빌드해야 합니다: %s\n' "$stock_kernel_dir" >&2
    exit 1
fi
if (( module_count == ${#module_sources[@]} )); then
    printf 'Linux 4.9.37용 ext4 모듈 포함: %s\n' "$module_dest"
fi

fakeroot -- bash -euo pipefail -c '
    root_dir=$1
    archive=$2
    mknod -m 0600 "$root_dir/dev/console" c 5 1
    mknod -m 0666 "$root_dir/dev/null" c 1 3
    cd "$root_dir"
    find . -print0 | sort -z | cpio --null -o --format=newc --owner=0:0 2>/dev/null | gzip -9n > "$archive"
' _ "$work_dir/root" "$work_dir/initramfs.cpio.gz"

install -m 0644 "$work_dir/initramfs.cpio.gz" "$out_dir/initramfs-debian.cpio.gz"

mkimage \
    -A arm -O linux -T ramdisk -C gzip \
    -a 0x00000000 -e 0x00000000 \
    -n 'Debian-root-switch-initramfs' \
    -d "$work_dir/initramfs.cpio.gz" \
    "$out_dir/uInitrd-debian" >/dev/null

dumpimage -l "$out_dir/uInitrd-debian" >/dev/null
(
    cd "$out_dir"
    sha256sum initramfs-debian.cpio.gz uInitrd-debian > uInitrd-debian.sha256
)

printf '생성 완료: %s\n' "$out_dir/uInitrd-debian"
dumpimage -l "$out_dir/uInitrd-debian"
