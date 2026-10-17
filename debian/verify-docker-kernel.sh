#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

bridge=br-dgtest
veth_host=dg-veth0
veth_peer=dg-veth1
work_dir=$(mktemp -d /tmp/digicap-docker-kernel.XXXXXX)
overlay_mounted=0

cleanup() {
    if (( overlay_mounted )); then
        umount "$work_dir/merged" 2>/dev/null || true
    fi
    ip link delete "$veth_host" 2>/dev/null || true
    ip link delete "$bridge" 2>/dev/null || true
    rm -rf -- "$work_dir"
}
trap cleanup EXIT INT TERM

if [[ $(id -u) -ne 0 ]]; then
    printf 'root로 실행해야 합니다.\n' >&2
    exit 1
fi

for command_name in awk grep id ip mkdir mktemp mount rm touch umount uname; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '필수 명령을 찾을 수 없습니다: %s\n' "$command_name" >&2
        exit 1
    }
done

for interface in "$bridge" "$veth_host" "$veth_peer"; do
    if ip link show "$interface" >/dev/null 2>&1; then
        printf '시험용 인터페이스가 이미 존재합니다: %s\n' "$interface" >&2
        exit 1
    fi
done

printf 'Kernel: '
uname -a

for controller in cpu cpuacct cpuset devices freezer memory pids; do
    if ! awk -v name="$controller" '$1 == name && $4 == 1 { found=1 } END { exit !found }' \
        /proc/cgroups; then
        printf '활성화되지 않은 cgroup controller: %s\n' "$controller" >&2
        exit 1
    fi
done
printf 'cgroup controllers: OK\n'

grep -qw overlay /proc/filesystems
printf 'overlay filesystem: OK\n'

ip link add "$bridge" type bridge
ip link add "$veth_host" type veth peer name "$veth_peer"
ip link set "$veth_host" master "$bridge"
test -L "/sys/class/net/$veth_host/master"
printf 'bridge + veth: OK\n'

test -e /proc/sys/net/bridge/bridge-nf-call-iptables
printf 'bridge netfilter: OK\n'

mkdir -p \
    "$work_dir/lower" "$work_dir/upper" "$work_dir/work" "$work_dir/merged"
printf 'overlay-read-test\n' > "$work_dir/lower/from-lower"
mount -t overlay overlay \
    -o "lowerdir=$work_dir/lower,upperdir=$work_dir/upper,workdir=$work_dir/work" \
    "$work_dir/merged"
overlay_mounted=1
grep -qx 'overlay-read-test' "$work_dir/merged/from-lower"
touch "$work_dir/merged/write-test"
test -e "$work_dir/upper/write-test"
umount "$work_dir/merged"
overlay_mounted=0
printf 'overlay read/write: OK\n'

if command -v iptables-legacy >/dev/null 2>&1; then
    iptables-legacy -t nat -L -n >/dev/null
    printf 'iptables legacy NAT table: OK\n'
else
    printf 'iptables-legacy: SKIP (iptables 패키지 설치 후 확인)\n'
fi

printf 'Docker bridge kernel checks: PASS\n'
