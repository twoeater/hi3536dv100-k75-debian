#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
firmware=${FIRMWARE:-"$project_dir/vendor/hikvision-k75.dav"}
out_dir=${OUT_DIR:-"$project_dir/debian/out/boot"}

for command_name in 7z awk binwalk dd dtc dumpimage sha256sum xxd; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    fi
done

if [[ ! -f "$firmware" ]]; then
    printf '원본 펌웨어를 찾을 수 없습니다: %s\n' "$firmware" >&2
    exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$out_dir"

7z e -so "$firmware" uImage > "$work_dir/uImage-stock"

stock_dtb_offset=$(binwalk "$work_dir/uImage-stock" | awk '/Flattened device tree/ && !found { print $1; found=1 }')
if [[ -z "$stock_dtb_offset" ]]; then
    printf '순정 uImage에서 appended DTB 위치를 찾지 못했습니다.\n' >&2
    exit 1
fi
if (( stock_dtb_offset <= 64 )); then
    printf '잘못된 순정 DTB 오프셋: %s\n' "$stock_dtb_offset" >&2
    exit 1
fi

# 우선 파일 끝까지 분리한 뒤 DTB 헤더의 totalsize를 사용해 정확히 잘라낸다.
dd if="$work_dir/uImage-stock" of="$work_dir/k75-with-tail.dtb" bs=1 skip="$stock_dtb_offset" status=none
dtb_size_hex=$(xxd -p -l 4 -s 4 "$work_dir/k75-with-tail.dtb")
dtb_size=$((16#$dtb_size_hex))
dd if="$work_dir/k75-with-tail.dtb" of="$work_dir/k75.dtb" bs=1 count="$dtb_size" status=none

dtc -I dtb -O dts -o "$work_dir/k75.dts" "$work_dir/k75.dtb" 2>/dev/null
if ! grep -q 'model = "HIKVISON K75 Platform Board"' "$work_dir/k75.dts"; then
    printf '추출한 DTB가 예상한 K75 보드가 아닙니다.\n' >&2
    exit 1
fi

cp "$work_dir/uImage-stock" "$out_dir/uImage-stock-signed"
cp "$work_dir/k75.dtb" "$out_dir/k75.dtb"
cp "$work_dir/k75.dts" "$out_dir/k75.dts"

dumpimage -l "$out_dir/uImage-stock-signed" >/dev/null
(
    cd "$out_dir"
    sha256sum uImage-stock-signed k75.dtb k75.dts > SHA256SUMS
)

printf 'K75 DTB 추출 완료: %s\n' "$out_dir/k75.dtb"
dumpimage -l "$out_dir/uImage-stock-signed"
