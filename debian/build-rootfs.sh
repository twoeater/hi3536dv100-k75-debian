#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
suite=${DEBIAN_SUITE:-bookworm}
mirror=${DEBIAN_MIRROR:-https://deb.debian.org/debian}
build_dir=${BUILD_DIR:-"$script_dir/build"}
rootfs_dir="$build_dir/rootfs-$suite-armhf"
output_tar=${OUTPUT_TAR:-"$script_dir/out/debian-$suite-armhf-rootfs.tar.gz"}
marker="$build_dir/.rootfs-$suite-armhf.digicap-generated"
debootstrap_cmd=${DEBOOTSTRAP:-}
debian_keyring=${DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}

usage() {
    cat <<'EOF'
사용법: ./debian/build-rootfs.sh [--clean]

환경 변수:
  DEBOOTSTRAP     debootstrap 실행 파일 경로
  DEBOOTSTRAP_DIR debootstrap 데이터 디렉터리 경로
  DEBIAN_KEYRING  Debian 아카이브 키링 경로
  DEBIAN_SUITE    기본값: bookworm
  DEBIAN_MIRROR   기본값: https://deb.debian.org/debian
  BUILD_DIR       임시 rootfs 디렉터리
  OUTPUT_TAR      결과 tar.gz 경로
EOF
}

clean=0
case ${1:-} in
    '') ;;
    --clean) clean=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [[ ${DIGICAP_FAKEROOT:-0} != 1 && $(id -u) -ne 0 ]]; then
    if ! command -v fakeroot >/dev/null 2>&1; then
        printf 'root가 아니라면 fakeroot가 필요합니다.\n' >&2
        exit 1
    fi
    exec fakeroot env DIGICAP_FAKEROOT=1 "$0" "$@"
fi

if [[ -z "$debootstrap_cmd" ]]; then
    debootstrap_cmd=$(command -v debootstrap || true)
fi
if [[ -z "$debootstrap_cmd" || ! -x "$debootstrap_cmd" ]]; then
    printf 'debootstrap을 찾지 못했습니다. DEBOOTSTRAP=/경로/debootstrap 을 지정하세요.\n' >&2
    exit 1
fi
if [[ ! -f "$debian_keyring" ]]; then
    printf 'Debian 아카이브 키링을 찾지 못했습니다: %s\n' "$debian_keyring" >&2
    printf 'debian-archive-keyring을 설치하거나 DEBIAN_KEYRING을 지정하세요.\n' >&2
    exit 1
fi

if (( clean )) && [[ -e "$rootfs_dir" ]]; then
    if [[ ! -f "$marker" ]]; then
        printf '생성 표시가 없는 디렉터리는 지우지 않습니다: %s\n' "$rootfs_dir" >&2
        exit 1
    fi
    rm -rf -- "$rootfs_dir"
fi
if [[ -e "$rootfs_dir" ]]; then
    printf '빌드 디렉터리가 이미 있습니다. 다시 만들려면 --clean을 사용하세요: %s\n' "$rootfs_dir" >&2
    exit 1
fi

mkdir -p "$rootfs_dir" "$(dirname "$output_tar")"
touch "$marker"

include_packages=busybox-static,ca-certificates,e2fsprogs,ifupdown,iproute2,isc-dhcp-client,kmod,less,locales,nano,net-tools,openssh-server,sudo,sysvinit-core,sysvinit-utils
"$debootstrap_cmd" \
    --foreign \
    --arch=armhf \
    --variant=minbase \
    --keyring="$debian_keyring" \
    --include="$include_packages" \
    "$suite" "$rootfs_dir" "$mirror"

cp -a "$script_dir/overlay/." "$rootfs_dir/"
chmod 0755 "$rootfs_dir/firstboot" "$rootfs_dir/usr/sbin/policy-rc.d"
chmod 0755 "$rootfs_dir"
chmod 0644 \
    "$rootfs_dir/etc/apt/sources.list" \
    "$rootfs_dir/etc/fstab" \
    "$rootfs_dir/etc/hosts" \
    "$rootfs_dir/etc/network/interfaces" \
    "$rootfs_dir/etc/ssh/sshd_config.d/10-digicap.conf"
mkdir -p "$rootfs_dir/dev"
rm -f "$rootfs_dir/dev/console" "$rootfs_dir/dev/null"
mknod -m 0600 "$rootfs_dir/dev/console" c 5 1
mknod -m 0666 "$rootfs_dir/dev/null" c 1 3
chown -R 0:0 "$rootfs_dir"

tar --numeric-owner --xattrs --acls -C "$rootfs_dir" -czf "$output_tar" .
(
    cd "$(dirname "$output_tar")"
    sha256sum "$(basename "$output_tar")" > "$(basename "$output_tar").sha256"
)

printf '생성 완료: %s\n' "$output_tar"
printf '이 tar는 ARM 장비에서 /firstboot가 debootstrap 2단계를 마쳐야 합니다.\n'
