# UART RAM 시험과 영구 설치

[English](INSTALL.md) | **한국어**

이 절차는 다음 조합에서만 검증했다.

- Hikvision DS-E04NI-Q1
- PCB <code>80578_P REV1.0</code>
- HiSilicon Hi3536DV100 K75
- U-Boot <code>2010.06-svn33219 (May 15 2019 - 19:24:05)</code>
- 16 MiB SPI NOR

주소와 U-Boot handler가 하나라도 다르면 중단한다. SPI를 변경하기 전에 UART
복구 경로, TFTP upload와 full SPI backup을 확보한다.

이 문서의 파티션 생성, dd, SPI erase와 SPI write 명령은 데이터를
파괴한다. 명령을 복사해 일괄 실행하지 말고, 각 검증 결과를 확인한 뒤
한 단계씩 사용자가 직접 실행한다.

## 1. 산출물 확인과 TFTP 준비

[BUILD.md](BUILD.ko.md)의 로컬 빌드가 끝나면 hash manifest를 먼저 확인한다.

~~~~sh
cd debian/out/boot-docker-bridge
sha256sum -c DEBIAN_BOOT-docker-bridge_SHA256SUMS
cd ../msata-image
sha256sum -c digicap-debian-msata-rootfs.sha256
~~~~

TFTP root에는 자동 부팅이 요청하는 정확한 이름 <code>uImage</code>를 만들지
않는다. 시험용 이름을 유지한다.

~~~~sh
sudo install -m 0644 \
  debian/out/boot-docker-bridge/uImage-debian-k75-docker-bridge \
  /srv/tftp/uImage-debian-k75-docker-bridge
sudo install -m 0644 \
  debian/out/boot-docker-bridge/initramfs-debian.cpio.gz \
  /srv/tftp/initramfs-debian.cpio.gz
sudo install -m 0644 \
  debian/out/boot/version-bootm-patch.bin \
  debian/out/boot/version-sf-patch.bin \
  /srv/tftp/
sudo install -m 0644 \
  debian/out/spi-cramfs-docker-bridge/digicap-debian-boot.cramfs.padded.bin \
  /srv/tftp/k75-debian-spi-cramfs-4MiB.bin
~~~~

PC의 TFTP 주소는 기본 U-Boot 환경과 같은 <code>192.0.0.128/24</code>,
보드는 <code>192.0.0.64</code>를 사용한다.

## 2. mSATA rootfs 기록

먼저 모델, 용량, transport와 mount 상태를 확인한다.

~~~~sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,FSTYPE,MOUNTPOINTS
~~~~

아래 예시의 <code>/dev/sdX</code>는 반드시 대상 mSATA 전체 장치로
바꾼다.

### 파괴 단계: 파티션 테이블 재작성

다음 명령은 대상 디스크의 기존 파티션과 데이터를 잃게 한다.

~~~~sh
printf 'label: dos\nunit: sectors\n\nstart=2048, type=83\n' |
  sudo sfdisk /dev/sdX
sudo partprobe /dev/sdX
~~~~

### 파괴 단계: ext4 image 기록

이 image는 전체 디스크용이 아니라 첫 번째 파티션용이다.

~~~~sh
gzip -t debian/out/msata-image/digicap-debian-msata-rootfs.ext4.gz
gzip -dc debian/out/msata-image/digicap-debian-msata-rootfs.ext4.gz |
  sudo dd of=/dev/sdX1 bs=4M conv=fsync status=progress
sudo e2fsck -f /dev/sdX1
sudo resize2fs /dev/sdX1
~~~~

완료 후 확인한다.

~~~~sh
sudo blkid /dev/sdX1
sudo e2fsck -fn /dev/sdX1
~~~~

filesystem label의 기본값은 <code>DIGICAP_MSATA</code>다. UUID는 image를
빌드할 때 생성되어 image 내부 <code>/etc/fstab</code>에 기록된다. 빌드마다
달라질 수 있으므로 <code>blkid</code>가 출력한 값을 사용한다.

## 3. UART에서 U-Boot prompt 진입

3.3 V TTL UART를 115200 8N1, flow control 없음으로 연다. 전원을 넣고
<code>Ctrl+U</code>로 autoboot를 멈춘다. upgrade 질문에는
<code>u</code>를 누르지 말고 <code>b</code>를 입력해
<code>HKVS #</code> prompt로 진입한다.

다음 두 값이 정확히 일치해야 한다.

~~~~text
HKVS # version
U-Boot 2010.06-svn33219 (May 15 2019 - 19:24:05)

HKVS # printenv
ipaddr=192.0.0.64
serverip=192.0.0.128
~~~~

## 4. SPI를 바꾸지 않는 RAM 부팅

~~~~text
tftp 0x84000000 initramfs-debian.cpio.gz
tftp 0x82000000 uImage-debian-k75-docker-bridge
tftp 0x8dc33e20 version-bootm-patch.bin
version 0x82000000
~~~~

이 단계는 SPI를 쓰지 않는다. Debian이 올라오면 확인한다.

~~~~sh
cat /proc/cmdline
findmnt -n -o SOURCE,FSTYPE,OPTIONS /
grep -E 'MemTotal|MemAvailable' /proc/meminfo
grep -i 'System RAM' /proc/iomem
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
stat -c '%A %a %U:%G %t:%T %n' \
  /dev/null /dev/zero /dev/full /dev/random /dev/urandom /dev/tty /dev/ptmx
dmesg | grep -E 'ata1|sda1|NCQ|I/O error|timeout'
~~~~

검증 장비에서 기대한 핵심 값은 다음과 같다.

~~~~text
root: /dev/sda1 ext4 rw,noatime
System RAM: 80000000-8fffffff
MemTotal: 약 253768 kB
SATA link: 3.0 Gbps
NCQ depth: 31
/dev/null: 0666 root:root
~~~~

Docker용 커널 기능도 시험한다.

~~~~sh
sudo ./debian/verify-docker-kernel.sh
~~~~

마지막 줄이 <code>Docker bridge kernel checks: PASS</code>여야 한다.

## 5. 16 MiB SPI 전체 백업

U-Boot의 세 번째 <code>tftp</code> 인자는 RAM에서 서버로 upload할 길이다.
tftpd-hpa 설정에 따라 서버에 쓰기 가능한 빈 파일을 먼저 만들어야 한다.

TFTP 서버에서 실행한다.

~~~~sh
sudo install -m 0666 /dev/null /srv/tftp/spi-nor-full-16MiB.bin
~~~~

U-Boot에서 RAM-only SPI hook을 사용해 읽고 upload한다.

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version read 0x82000000 0x00000000 0x01000000
tftp 0x82000000 spi-nor-full-16MiB.bin 0x01000000
~~~~

probe 결과는 다음이어야 한다.

~~~~text
16384 KiB hi_fmc at 0:0 is now current device
~~~~

서버에서 정확히 16,777,216바이트인지 확인하고 hash를 기록한다.

~~~~sh
stat -c '%s %n' /srv/tftp/spi-nor-full-16MiB.bin
sha256sum /srv/tftp/spi-nor-full-16MiB.bin
~~~~

백업을 서로 독립된 두 위치에 복사한다.

## 6. 4 MiB CramFS download 왕복 검증

TFTP 서버에서 upload 대상 빈 파일을 만든다.

~~~~sh
sudo install -m 0666 /dev/null /srv/tftp/cramfs-preflash.bin
~~~~

U-Boot에서 image를 RAM으로 받은 뒤 같은 4 MiB를 다시 upload한다.

~~~~text
tftp 0x82000000 k75-debian-spi-cramfs-4MiB.bin
tftp 0x82000000 cramfs-preflash.bin 0x00400000
~~~~

서버에서 비교한다.

~~~~sh
cmp /srv/tftp/k75-debian-spi-cramfs-4MiB.bin \
  /srv/tftp/cramfs-preflash.bin
sha256sum /srv/tftp/k75-debian-spi-cramfs-4MiB.bin \
  /srv/tftp/cramfs-preflash.bin
~~~~

<code>cmp</code>가 성공하고 두 hash가 같을 때만 다음 단계로 간다.

## 7. CramFS를 SPI에 기록

### 파괴 단계: SPI 0x000a0000부터 4 MiB erase/write

이 명령은 SPI의 <code>0x000a0000-0x0049ffff</code>를 지우고 바꾼다.
RAM에는 6단계에서 검증한 파일이 그대로 있어야 한다.

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version erase 0x000a0000 0x00400000
version write 0x82000000 0x000a0000 0x00400000
version read 0x82000000 0x000a0000 0x00400000
~~~~

readback을 upload한다. 서버에서 먼저 빈 파일을 만든다.

~~~~sh
sudo install -m 0666 /dev/null /srv/tftp/cramfs-readback.bin
~~~~

~~~~text
tftp 0x82000000 cramfs-readback.bin 0x00400000
~~~~

~~~~sh
cmp /srv/tftp/k75-debian-spi-cramfs-4MiB.bin \
  /srv/tftp/cramfs-readback.bin
sha256sum /srv/tftp/k75-debian-spi-cramfs-4MiB.bin \
  /srv/tftp/cramfs-readback.bin
~~~~

readback이 일치하지 않으면 reset하거나 전원을 끄지 말고 UART 상태를
유지한 채 원인을 확인한다.

## 8. 장비별 autoboot sector 생성

vendor 초기화 코드는 매 부팅 때 U-Boot 환경의 <code>default</code>를
<code>cramfsload 0x82000000 uImage;</code>로 다시 설정한다. 저장된 환경만
바꿔서는 cold boot가 유지되지 않으므로, 자기 장비의 sector를 읽어 해당
고정 문자열만 <code>run debian</code>으로 바꾼다.

서버에서 upload 파일을 만든다.

~~~~sh
sudo install -m 0666 /dev/null \
  /srv/tftp/uboot-sector-40000-current.bin
~~~~

U-Boot에서 현재 sector를 읽는다.

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version read 0x82000000 0x00040000 0x00010000
tftp 0x82000000 uboot-sector-40000-current.bin 0x00010000
~~~~

PC에서 generator를 실행한다.

~~~~sh
python3 debian/build-uboot-autoboot-patch.py \
  /srv/tftp/uboot-sector-40000-current.bin \
  --tftp-dir /srv/tftp
~~~~

generator는 길이, 대상 문자열의 유일성, 정확한 offset과 인접 field를
검사한다. 예상 bytes가 아니면 결과를 만들지 않는다. 출력 sector는 이
장비 전용이다.

기록 전 TFTP 왕복도 비교한다.

~~~~sh
sudo install -m 0666 /dev/null \
  /srv/tftp/uboot-sector-40000-preflash.bin
~~~~

~~~~text
tftp 0x82000000 uboot-sector-40000-run-debian.bin
tftp 0x82000000 uboot-sector-40000-preflash.bin 0x00010000
~~~~

~~~~sh
cmp /srv/tftp/uboot-sector-40000-run-debian.bin \
  /srv/tftp/uboot-sector-40000-preflash.bin
~~~~

### 파괴 단계: SPI 0x00040000 sector erase/write

비교가 성공한 경우에만 실행한다.

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
tftp 0x82000000 uboot-sector-40000-run-debian.bin
version erase 0x00040000 0x00010000
version write 0x82000000 0x00040000 0x00010000
version read 0x82000000 0x00040000 0x00010000
~~~~

readback을 upload해 생성 파일과 비교한다.

~~~~sh
sudo install -m 0666 /dev/null \
  /srv/tftp/uboot-sector-40000-readback.bin
~~~~

~~~~text
tftp 0x82000000 uboot-sector-40000-readback.bin 0x00010000
~~~~

~~~~sh
cmp /srv/tftp/uboot-sector-40000-run-debian.bin \
  /srv/tftp/uboot-sector-40000-readback.bin
~~~~

## 9. U-Boot 환경 저장

sector readback이 일치하면 U-Boot에서 실행한다.

~~~~text
setenv debian 'cramfsload 0x84000000 initrd;cramfsload 0x82000000 uImage;cramfsload 0x8dc33e20 vboot;version 0x82000000'
setenv default 'run debian'
saveenv
printenv default debian
~~~~

기대값:

~~~~text
default=run debian
debian=cramfsload 0x84000000 initrd;cramfsload 0x82000000 uImage;cramfsload 0x8dc33e20 vboot;version 0x82000000
~~~~

먼저 <code>reset</code>으로 warm boot를 확인한다. Debian이 정상으로 올라온
뒤 전원을 완전히 끄고 다시 켜 cold boot도 확인한다.

## 10. 설치 후 확인

~~~~sh
findmnt -n -o SOURCE,FSTYPE,OPTIONS /
test ! -e /firstboot && echo FIRSTBOOT_DONE || echo FIRSTBOOT_PENDING
stat -c '%U:%G %a %n' /usr/bin/passwd /usr/bin/su /usr/bin/sudo
swapon --show
dmesg | grep -E 'ata1|sda1|NCQ|I/O error|timeout' | tail -30
~~~~

첫 부팅이면 UART에서 Debian 사용자 암호를 설정한다. 완료 후 root는
<code>/dev/sda1</code>, swap은 <code>/swapfile</code>이어야 한다.

## 복구 원칙

UART에서 autoboot를 중단할 수 있으면 TFTP RAM 부팅과 RAM-only SPI hook은
그대로 사용할 수 있다. 복구에는 반드시 해당 장비에서 저장한 full SPI
backup과 원본 64 KiB sector를 사용한다. 주소와 길이를 다시 검증하지 않은
full-chip write 명령은 사용하지 않는다.
