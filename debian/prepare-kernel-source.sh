#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
openipc_repository=${OPENIPC_LINUX_REPOSITORY:-https://github.com/OpenIPC/linux.git}
openipc_commit=${OPENIPC_LINUX_COMMIT:-6b8ca794ec3e1e35ee260377443a6a729df27e91}
kernel_dir=${KERNEL_DIR:-"$script_dir/build/linux-4.9.37-hi3536dv100-k75"}
boot_fragment=${K75_BOOT_CONFIG:-"$script_dir/kernel-configs/k75-boot.config"}
container_fragment=${KERNEL_CONFIG_FRAGMENT:-"$script_dir/kernel-configs/docker-bridge.config"}
local_patch=${K75_KERNEL_PATCH:-"$script_dir/kernel-patches/0001-hi3536dv100-k75-boot-fixes.patch"}
expected_config_sha256=${EXPECTED_CONFIG_SHA256:-c70a0cd192257b9d12b0653ebe6d0a3a039cbd30645b2b79926ffbfa7101c096}

for command_name in git make patch sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    }
done

for input_file in "$boot_fragment" "$container_fragment" "$local_patch"; do
    [[ -f "$input_file" ]] || {
        printf '입력 파일을 찾을 수 없습니다: %s\n' "$input_file" >&2
        exit 1
    }
done

if [[ ! "$openipc_commit" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'OPENIPC_LINUX_COMMIT은 40자리 Git commit이어야 합니다: %s\n' \
        "$openipc_commit" >&2
    exit 2
fi

if [[ -e "$kernel_dir" ]]; then
    printf '기존 커널 트리를 덮어쓰지 않습니다: %s\n' "$kernel_dir" >&2
    exit 2
fi

work_dir=$(mktemp -d)
cleanup()
{
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p "$(dirname "$kernel_dir")"
source_dir="$work_dir/linux"
git init -q "$source_dir"
git -C "$source_dir" remote add origin "$openipc_repository"
if ! git -C "$source_dir" fetch -q --depth=1 origin "$openipc_commit"; then
    printf 'OpenIPC Linux commit을 가져오지 못했습니다.\n' >&2
    printf 'repository=%s\ncommit=%s\n' \
        "$openipc_repository" "$openipc_commit" >&2
    exit 1
fi
git -C "$source_dir" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD

actual_source_commit=$(git -C "$source_dir" rev-parse HEAD)
if [[ "$actual_source_commit" != "$openipc_commit" ]]; then
    printf '가져온 OpenIPC Linux commit이 고정값과 다릅니다.\n' >&2
    printf 'expected=%s\nactual=%s\n' \
        "$openipc_commit" "$actual_source_commit" >&2
    exit 1
fi

patch --batch --forward -d "$source_dir" -p1 < "$local_patch"
git -C "$source_dir" diff --check

make -s -C "$source_dir" ARCH=arm hi3536dv100_full_defconfig
(
    cd "$source_dir"
    ARCH=arm scripts/kconfig/merge_config.sh -m .config "$boot_fragment" "$container_fragment"
    make -s ARCH=arm olddefconfig
)

actual_config_sha256=$(sha256sum "$source_dir/.config" | awk '{print $1}')
if [[ "$actual_config_sha256" != "$expected_config_sha256" ]]; then
    printf '생성된 커널 설정의 SHA-256이 검증값과 다릅니다.\n' >&2
    printf 'expected=%s\nactual=%s\n' "$expected_config_sha256" "$actual_config_sha256" >&2
    exit 1
fi

mv "$source_dir" "$kernel_dir"

printf '커널 소스 준비 완료: %s\n' "$kernel_dir"
printf 'OpenIPC Linux commit: %s\n' "$actual_source_commit"
printf 'config sha256: %s\n' "$actual_config_sha256"
printf '다음 단계: KERNEL_DIR=%q ./debian/build-docker-bridge-images.sh\n' "$kernel_dir"
