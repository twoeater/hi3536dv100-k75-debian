# 소스 준비와 이미지 빌드

[English](BUILD.md) | **한국어**

이 문서는 고정된 공개 커널 소스와 사용자가 직접 연결한 보드 펌웨어로
검증한 커널과 Debian 이미지를 로컬에서 생성하는 절차를 설명한다.

## 빌드 호스트

검증한 호스트는 Ubuntu 24.04 x86-64와
<code>arm-linux-gnueabi-gcc 13.3.0</code>이다. Debian/Ubuntu 계열에서
필요한 도구는 대략 다음 패키지로 설치할 수 있다.

~~~~sh
sudo apt install \
  bc binwalk bison build-essential cpio cramfsprogs debootstrap \
  debian-archive-keyring device-tree-compiler e2fsprogs fakeroot flex \
  gcc-arm-linux-gnueabi git libssl-dev patch p7zip-full python3 \
  qemu-user-static u-boot-tools xz-utils
~~~~

배포판에 따라 패키지 이름이 다를 수 있다. 각 스크립트는 실행 전에 필요한
명령과 입력 파일을 검사한다.

## 외부 입력

[vendor/README.md](../vendor/README.md)의 이름으로 사용자 장비용 순정
펌웨어 하나를 심볼릭 링크한다.

~~~~text
vendor/
└── hikvision-k75.dav -> 사용자 장비용 순정 펌웨어
~~~~

커널은 [OpenIPC Linux](https://github.com/OpenIPC/linux)의
<code>hisilicon-hi3536dv100</code> branch에서 자동으로 받는다. 실제 입력은
branch 이름이 아니라 다음 40자리 commit으로 고정한다.

~~~~text
6b8ca794ec3e1e35ee260377443a6a729df27e91
~~~~

출처와 license 정보는 [THIRD_PARTY.md](../THIRD_PARTY.md)에 기록되어 있다.

## 커널 소스 준비

다음 명령은 고정된 OpenIPC Linux commit을 shallow fetch하고 저장소의 K75
패치를 적용한다.

~~~~sh
./debian/prepare-kernel-source.sh
~~~~

생성 위치는 기본적으로
<code>debian/build/linux-4.9.37-hi3536dv100-k75</code>다. 기존 디렉터리는
덮어쓰지 않는다.

설정은 다음 순서로 만든다.

1. OpenIPC tree의 <code>hi3536dv100_full_defconfig</code>
2. <code>debian/kernel-configs/k75-boot.config</code>
3. <code>debian/kernel-configs/docker-bridge.config</code>
4. <code>make ARCH=arm olddefconfig</code>

완성된 config의 검증 SHA-256은
<code>c70a0cd192257b9d12b0653ebe6d0a3a039cbd30645b2b79926ffbfa7101c096</code>다.
다른 값이면 준비 스크립트가 중단된다.

저장소의 커널 패치는 다음 변경만 담는다.

- 최신 assembler가 이해하는 ARM section flag 표기
- pinned OpenIPC commit에 포함된 generated DTC lexer 수정과 일치하도록
  DTC lexer source의 중복 <code>yylloc</code> 선언 제거
- K75의 PL011 early UART에 필요한 32-bit register write
- DT의 <code>hisilicon,phy-mode</code>로 SATA PHY 1.5/3.0 Gbps 선택

OpenIPC의 로컬 mirror와 출력 위치는 환경변수로 바꿀 수 있다. mirror에서도
동일한 pinned commit을 가져올 수 있어야 한다.

~~~~sh
OPENIPC_LINUX_REPOSITORY=/path/to/openipc-linux.git \
KERNEL_DIR=/path/to/output-kernel \
  ./debian/prepare-kernel-source.sh
~~~~

## K75 보드 DTB 준비

현재 K75 DTB는 사용자가 보유한 순정 펌웨어에서 로컬로 추출한다.

~~~~sh
./debian/build-boot-images.sh
~~~~

스크립트는 순정 펌웨어의 uImage에서
<code>HIKVISON K75 Platform Board</code> DTB를 찾는다. 생성된
<code>debian/out/boot/k75.dtb</code>, DTS와 순정 uImage 사본은 이후 로컬
빌드 단계에서 사용한다.

다른 위치의 입력은 다음처럼 지정한다.

~~~~sh
FIRMWARE=/path/to/device-firmware.dav \
  ./debian/build-boot-images.sh
~~~~

## Debian rootfs

~~~~sh
./debian/build-rootfs.sh --clean
~~~~

이 스크립트는 Debian Bookworm ARMHF minbase rootfs를 debootstrap의
foreign mode로 만들고, SSH·네트워크·SysV init·sudo·BusyBox와 K75 overlay를
추가한다. 결과는 다음 두 파일이다.

~~~~text
debian/out/debian-bookworm-armhf-rootfs.tar.gz
debian/out/debian-bookworm-armhf-rootfs.tar.gz.sha256
~~~~

ARM에서 debootstrap 두 번째 단계와 사용자 암호 설정은 첫 부팅의
<code>/firstboot</code>가 처리한다.

## 커널, initramfs, uImage와 SPI CramFS

앞 단계 세 가지가 끝난 뒤 실행한다.

~~~~sh
./debian/build-docker-bridge-images.sh
~~~~

스크립트가 수행하는 작업은 다음과 같다.

1. 검증한 Kconfig fragment를 다시 병합하고 누락된 옵션이 없는지 검사한다.
2. ARM zImage와 모듈을 빌드한다.
3. BusyBox initramfs에 mbcache, jbd2와 ext4 모듈을 넣는다.
4. K75 DTB에 256 MiB bootargs, initrd 범위, timer clock과 SATA PHY mode를
   기록한다.
5. zImage 뒤에 DTB를 붙여 Legacy uImage를 만든다.
6. uImage, raw initramfs와 RAM-only boot hook을 4 MiB CramFS image로 묶는다.

주요 결과는 다음 경로에 생긴다.

~~~~text
debian/out/boot-docker-bridge/
├── uImage-debian-k75-docker-bridge
├── initramfs-debian.cpio.gz
├── version-bootm-patch.bin
└── DEBIAN_BOOT-docker-bridge_SHA256SUMS

debian/out/spi-cramfs-docker-bridge/
├── digicap-debian-boot.cramfs
├── digicap-debian-boot.cramfs.padded.bin
└── SPI_CRAMFS_LAYOUT.txt
~~~~

패딩된 SPI 파일은 정확히 4 MiB이며 대상 범위는
<code>0x000a0000-0x0049ffff</code>다. 스크립트는 기존 출력 파일을
덮어쓰지 않는다.

## U-Boot RAM hook 생성

~~~~sh
python3 debian/ram-loader/make_abort_patch.py
~~~~

설치에서 쓰는 파일은
<code>debian/out/boot/version-bootm-patch.bin</code>과
<code>debian/out/boot/version-sf-patch.bin</code>이다. 두 파일은 12바이트
RAM patch이며 SPI 내용을 포함하지 않는다. 구조와 정확한 적용 범위는
[UBOOT.md](UBOOT.ko.md)에 설명한다.

## mSATA rootfs image

~~~~sh
sudo ./debian/build-msata-root-image.sh
~~~~

기본값은 2 GiB ext4 파일시스템 image와 512 MiB swapfile이다.

~~~~text
debian/out/msata-image/digicap-debian-msata-rootfs.ext4
debian/out/msata-image/digicap-debian-msata-rootfs.ext4.gz
debian/out/msata-image/digicap-debian-msata-rootfs.sha256
~~~~

이 파일은 전체 디스크 image가 아니라 파티션에 쓰는 ext4 filesystem
image다. 실제 mSATA 파티션으로 기록하고 확장하는 절차는
[INSTALL.md](INSTALL.ko.md)에 있다. 기본적으로 <code>mkfs.ext4</code>가 새
UUID를 생성하고 스크립트가 그 값을 image 내부 <code>/etc/fstab</code>에
기록한다. 특정 UUID가 필요할 때만 <code>FILESYSTEM_UUID</code>를 지정한다.

## 이름과 재현성

일부 파일명과 root marker에는 초기 프로젝트명인
<code>digicap</code>이 남아 있다. 이는 initramfs와 기존 설치 이미지의
호환 식별자이며, 지원 범위는 Hi3536DV100 전체가 아니라 K75 보드다.

커널 source commit과 config 준비 결과는 고정값으로 검증할 수 있다. uImage header의
timestamp, 당시 Debian archive 패키지와 filesystem 생성 시점 때문에 모든
최종 image가 매번 byte-for-byte 동일하다고 보장하지는 않는다. 각 빌드의
manifest와 SHA-256을 설치에 사용한다.
