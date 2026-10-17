# Debian build tools for Hi3536DV100 K75

[English](README.md) | **한국어**

이 디렉터리는 K75 보드용 Debian rootfs와 boot image를 로컬에서 만드는
도구 모음이다. 커널 소스는 고정된 OpenIPC Linux commit에서 빌드할 때
받는다.

전체 흐름은 다음 문서를 먼저 읽는다.

- [소스 준비와 빌드](../docs/BUILD.ko.md)
- [UART 시험과 설치](../docs/INSTALL.ko.md)
- [U-Boot hook 구조](../docs/UBOOT.ko.md)

## 권장 build 순서

~~~~sh
./debian/prepare-kernel-source.sh
./debian/build-rootfs.sh --clean
./debian/build-boot-images.sh
./debian/build-docker-bridge-images.sh
python3 ./debian/ram-loader/make_abort_patch.py
sudo ./debian/build-msata-root-image.sh
~~~~

입력 파일은 [vendor/README.md](../vendor/README.md)의 이름으로 연결한다.
모든 결과는 Git에서 제외되는 <code>debian/build/</code>와
<code>debian/out/</code> 아래에 생긴다.

## production 경로

| 파일 | 역할 | 저장장치 변경 |
|---|---|---|
| <code>prepare-kernel-source.sh</code> | pinned OpenIPC Linux, local patch와 config를 합쳐 검증한 source tree 생성 | 없음 |
| <code>build-rootfs.sh</code> | Debian Bookworm ARMHF rootfs tar 생성 | 없음 |
| <code>build-boot-images.sh</code> | 사용자 firmware에서 K75 DTB와 로컬 검증용 순정 uImage 추출 | 없음 |
| <code>build-docker-bridge-images.sh</code> | kernel, modules, initramfs, uImage와 4 MiB SPI CramFS를 연속 생성 | 없음 |
| <code>build-initramfs.sh</code> | BusyBox root-switch initramfs와 ext4 modules 생성 | 없음 |
| <code>package-debian-k75.sh</code> | K75 DTB 수정, appended-DTB Legacy uImage와 boot hook 생성 | 없음 |
| <code>build-spi-cramfs.py</code> | uImage, initrd, vboot를 little-endian CramFS와 FF padding으로 묶음 | 없음 |
| <code>build-msata-root-image.sh</code> | 파티션용 ext4 rootfs image와 swapfile 생성 | loop mount 사용, 실제 disk는 변경하지 않음 |
| <code>build-uboot-autoboot-patch.py</code> | 사용자 장비의 64 KiB sector에서 command field만 변경 | 출력 생성만 수행 |
| <code>ram-loader/make_abort_patch.py</code> | exact U-Boot용 RAM-only command entry patch 생성 | 없음 |
| <code>verify-docker-kernel.sh</code> | cgroup, overlayfs, bridge/veth와 netfilter runtime 검사 | 임시 interface와 mount만 생성 후 정리 |

실제 mSATA partition과 SPI NOR를 수정하는 명령은 build script에 넣지 않았다.
사용자가 UART 출력과 readback을 확인하면서
[INSTALL.md](../docs/INSTALL.ko.md)의 각 파괴 단계를 직접 실행한다.

## 설정과 source patch

<code>kernel-configs/k75-boot.config</code>는 early UART와 modular ext4를
설정한다. <code>kernel-configs/docker-bridge.config</code>는 devtmpfs,
cgroup, seccomp, overlayfs, bridge/veth, netfilter와 legacy iptables 기능을
추가한다.

<code>kernel-patches/0001-hi3536dv100-k75-boot-fixes.patch</code>는 K75
부팅에서 확인한 최소 source 변경을 담는다. HiSilicon SoC enablement가
포함된 기반 tree는 OpenIPC의 정확한 commit을 fetch하며, 그 source 자체는
이 저장소에 복사하거나 submodule로 등록하지 않는다.

## initramfs

<code>initramfs/init</code>는 다음 순서로 동작한다.

1. proc, sysfs, run과 devtmpfs를 mount한다.
2. devtmpfs가 없는 시험용 vendor kernel에서는 tmpfs와 BusyBox mdev를 쓴다.
3. 표준 문자 장치 mode를 0666으로 맞춘다.
4. mbcache, jbd2와 ext4 module이 포함되어 있으면 순서대로 적재한다.
5. kernel cmdline의 <code>digicap.root_transport</code>에 맞는 block device를
   찾는다.
6. ext4 filesystem의 <code>.digicap-debian-root</code> marker를 확인한다.
7. dev, proc, sys와 run을 옮긴 뒤 firstboot 또는 SysV init으로 switch_root한다.

지원하는 transport 값은 <code>sata</code>, <code>usb</code>와
<code>any</code>다. production uImage는 <code>sata</code>를 사용한다.

## Debian overlay

<code>overlay/</code>에는 다음 설정만 둔다.

- Debian Bookworm apt sources
- hostname과 hosts
- DHCP network interface
- SSH 기본 설정
- SysV firstboot
- rootfs 생성 중 service 자동 시작을 막는 policy-rc.d

firstboot는 debootstrap 두 번째 단계를 실행하고 Debian 사용자 암호를
UART에서 받는다. 성공하면 자기 자신을 제거하고 SysV init으로 전환한다.

## 대체 rootfs 설치 도구

<code>install-rootfs.sh</code>는 이미 mount된 빈 ext4 partition에 rootfs
tar를 직접 설치하는 대체 경로다. 정확한 mountpoint를 다시 입력하게 하며,
root filesystem이나 비어 있지 않은 target을 거부한다.

일반적인 재현과 배포에는 partition image를 만드는
<code>build-msata-root-image.sh</code>를 사용한다.

## bring-up 기록

다음 파일은 초기 조사와 복구 연구를 보존하지만 현재 설치 경로에는 쓰지
않는다.

- <code>build-ram-loader.sh</code>
- <code>ram-loader/loader.S</code>와 <code>loader.ld</code>
- <code>build-spi-boot-bundle.py</code>

이 경로는 kernel entry, cache/MMU 상태와 raw SPI 배치를 찾을 때 사용했다.
새 설치에서는 CramFS production 경로를 따른다.

## 출력 덮어쓰기 정책

대부분의 script는 기존 source tree나 image를 덮어쓰지 않는다. 다시
빌드하려면 어떤 입력에서 만든 결과인지 확인한 뒤 해당
<code>debian/build/</code> 또는 <code>debian/out/</code> 하위 디렉터리를
사용자가 정리한다. vendor 입력, SPI backup과 실제 block device를 자동으로
삭제하는 clean target은 제공하지 않는다.
