# HiSilicon Hi3536DV100 K75에서 Debian 실행

[English](README.md) | **한국어**

Hikvision K75 보드에서 Debian 12 Bookworm ARMHF를 실행하기 위한 비공식
보드 포트다. 검증 장비는 Hikvision DS-E04NI-Q1, PCB
<code>80578_P REV1.0</code>이며, Linux 커널과 initramfs는 16 MiB SPI
NOR의 CramFS에서 읽고 Debian rootfs는 mSATA에서 마운트한다.

이 프로젝트는 모든 Hi3536DV100 장비에 공통으로 적용하는 펌웨어가 아니다.
SoC가 같아도 DRAM, PHY, GPIO, 저장장치 배선, DTB와 U-Boot가 다르면 그대로
사용할 수 없다.

## 호환 범위

| 항목 | 검증값 |
|---|---|
| SoC | HiSilicon Hi3536DV100, ARMv7 Cortex-A7 |
| 제품 | Hikvision DS-E04NI-Q1 |
| PCB | <code>80578_P REV1.0</code> |
| DT model | <code>HIKVISON K75 Platform Board</code> |
| U-Boot | <code>2010.06-svn33219 (May 15 2019 - 19:24:05)</code> |
| RAM | 256 MiB, <code>mem=256M</code> |
| 부팅 저장장치 | 16 MiB SPI NOR의 4 MiB CramFS 영역 |
| rootfs | mSATA 첫 번째 ext4 파티션 |
| 콘솔 | PL011 3.3 V TTL, 115200 8N1 |

다음 항목을 실제 장비에서 확인했다.

- Linux 4.9.37, Debian 12 Bookworm ARMHF, SysV init
- 256 MiB 전체 인식과 <code>memtester 200M 1</code> 통과
- SATA 3.0 Gbps, NCQ depth 31, ext4, 512 MiB swapfile
- Ethernet DHCP, USB, SSH, apt, 하드웨어 reboot
- warm reset과 완전 전원 차단 후 자동 부팅
- devtmpfs와 표준 장치 mode 0666
- cgroup, overlayfs, bridge, veth, bridge netfilter와 legacy iptables용
  커널 기능

HDMI 출력, 카메라 입력, 영상 인코더와 HiSilicon MPP 가속은 구현하지 않았다.

## 저장소가 제공하는 것

이 저장소는 소스와 로컬 생성 도구를 제공한다.

- 고정된 [OpenIPC Linux Hi3536DV100 트리](https://github.com/OpenIPC/linux/tree/hisilicon-hi3536dv100)를
  받아 K75 패치와 검증된 설정을 적용하는 커널 준비 스크립트
- K75에서 필요한 작은 커널 패치와 검증한 Kconfig fragment
- Debian rootfs, initramfs, Legacy uImage와 SPI CramFS 생성 스크립트
- 정확한 U-Boot 빌드에서 <code>version</code> 명령을 RAM에서 임시로
  연결하는 패치 생성기
- 각 장비가 직접 읽어 낸 U-Boot sector로 자동 부팅 sector를 만드는 생성기
- 설치 전 RAM 부팅과 설치 후 Docker 커널 기능 검증 절차

커널 소스는 [THIRD_PARTY.md](THIRD_PARTY.md)에 기록한 정확한 OpenIPC
commit에서 빌드할 때 받는다. 사용자가 제공하는 Hikvision 펌웨어는 저장소
밖에 두고 [vendor/README.md](vendor/README.md)의 로컬 심볼릭 링크로 연결한다.

## 소스와 라이선스

이 저장소는 GPL-2.0-only로 배포하며 자세한 조건은 [LICENSE](LICENSE)에
있다. 커널 준비 단계는 현재 OpenIPC Linux commit
<code>6b8ca794ec3e1e35ee260377443a6a729df27e91</code>을 고정한다. checkout한
커널의 저작권 고지와 <code>COPYING</code>은 그대로 유지하고, 이 프로젝트의
변경은 별도 patch로 관리한다. 출처는 [THIRD_PARTY.md](THIRD_PARTY.md)에
기록했다.

## 부팅 구조

~~~~text
Hikvision U-Boot vendor default routine
  -> default=run debian
  -> SPI CramFS: initrd -> RAM 0x84000000
  -> SPI CramFS: uImage -> RAM 0x82000000
  -> SPI CramFS: 12-byte version hook -> RAM 0x8dc33e20
  -> version 0x82000000
  -> Linux 4.9.37 + appended K75 DTB
  -> initramfs가 SATA의 .digicap-debian-root를 탐색
  -> switch_root로 mSATA Debian 실행
~~~~

U-Boot 전체나 커널을 SPI의 부트로더 영역에 덮어쓰지 않는다. 영구 변경은
SPI의 기존 CramFS 영역과, vendor 기본 명령 문자열이 있는 장비별 64 KiB
sector에 한정한다.

## 문서

1. [외부 입력 연결](vendor/README.md)
2. [소스 준비와 이미지 빌드](docs/BUILD.ko.md)
3. [UART RAM 시험과 영구 설치](docs/INSTALL.ko.md)
4. [U-Boot version hook 구조](docs/UBOOT.ko.md)
5. [스크립트 색인](debian/README.ko.md)

## 안전 원칙

SPI나 mSATA를 수정하기 전에 UART로 U-Boot prompt에 진입할 수 있어야 한다.
새 커널과 initramfs는 먼저 TFTP로 RAM에서만 부팅한다. 영구 기록 전에는
16 MiB SPI 전체를 읽어 저장하고, TFTP 다운로드 내용을 다시 업로드해
원본과 비교한다. 기록 후에도 SPI readback을 파일 단위로 비교한다.

다른 장비에서 가져온 전체 SPI dump나 패치된 64 KiB sector를 재사용하면
안 된다. 설치 문서의 파티션 생성, dd, SPI erase와 SPI write 명령은
대상 데이터를 파괴한다. 각 단계에서 모델, 용량, 주소, 길이와 SHA-256을
확인한 뒤 사용자가 직접 실행한다.

## 검증 상태

하드웨어 부팅 결과는 검증했으며, 커널 소스 준비 과정도 고정한 OpenIPC
source commit에서 다시 실행해 검증했다. 보드 DTB는 사용자가 보유한 순정
펌웨어에서 빌드할 때 로컬로 추출한다.
