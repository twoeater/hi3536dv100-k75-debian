# U-Boot version hook 구조

[English](UBOOT.md) | **한국어**

이 문서는 Hikvision의 정확한 U-Boot 빌드
<code>2010.06-svn33219 (May 15 2019 - 19:24:05)</code>에서 확인한 동작을
기록한다. 아래 RAM 주소와 함수 주소는 다른 U-Boot, 다른 firmware build나
다른 Hi3536DV100 보드에 적용할 수 없다.

## 왜 hook이 필요한가

이 U-Boot는 표시되는 명령과 실제 vendor boot path가 다르다.

- 직접 <code>bootm</code>을 실행하면 Hikvision RSA 검사가 먼저 수행된다.
  <code>setenv verify n</code>은 이 RSA 검사에 영향을 주지 않는다.
- help에는 <code>sf</code>가 보이지만 보안 filter 때문에 직접 실행이
  동작하지 않는 상태가 있다.
- <code>cramfsload</code>는 일반 command table에는 없고 vendor default
  routine의 dispatcher에서 처리된다. 일반 <code>run bootcmd</code> 경로로
  들어가면 Unknown command가 발생할 수 있다.

RAM에 올라온 U-Boot command entry의 가변 field만 바꾸면, 허용된
<code>version</code> 이름으로 기존 U-Boot 내부 handler를 호출할 수 있다.
stored U-Boot code를 고치지 않으며 reset하거나 전원을 끄면 RAM hook은
사라진다.

## 12바이트 command entry patch

<code>0x8dc33e20</code>은 이 빌드의 live <code>version</code> command
entry에서 다음 세 개의 32-bit little-endian field가 놓인 주소다.

~~~~text
offset +0x00: maxargs
offset +0x04: repeatable
offset +0x08: command handler pointer
~~~~

name, usage와 help pointer는 바꾸지 않는다. 생성기는 다음 tuple을 만든다.

| 출력 | maxargs | repeatable | handler | 용도 |
|---|---:|---:|---:|---|
| <code>version-bootm-patch.bin</code> | 4 | 1 | <code>0x8dc12360</code> | U-Boot의 <code>do_bootm</code> |
| <code>version-sf-patch.bin</code> | 5 | 1 | <code>0x8dc1532c</code> | SPI flash handler |
| <code>version-mainloop-patch.bin</code> | 1 | 1 | <code>0x8dc19e44</code> | 일반 U-Boot main loop 시험 |
| <code>version-defaultboot-patch.bin</code> | 1 | 1 | <code>0x8dd041b8</code> | vendor default routine 시험 |

로컬에서 생성한다.

~~~~sh
python3 debian/ram-loader/make_abort_patch.py
~~~~

production 설치에 필요한 것은 bootm과 sf 두 patch다. mainloop와
defaultboot patch는 bring-up 때 cold boot 경로를 RAM에서 시험하기 위해
사용했다.

## RAM boot handler 사용

~~~~text
tftp 0x84000000 initramfs-debian.cpio.gz
tftp 0x82000000 uImage-debian-k75-docker-bridge
tftp 0x8dc33e20 version-bootm-patch.bin
version 0x82000000
~~~~

Legacy uImage header에는 appended K75 DTB와 initramfs의 고정 RAM 범위가
기록되어 있다. handler는 Legacy checksum을 검사하고 kernel을 시작한다.

## SPI handler 사용

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version read 0x82000000 0x00000000 0x01000000
~~~~

probe 결과가 <code>16384 KiB hi_fmc at 0:0 is now current device</code>인지
확인한다. read는 backup과 검증에 먼저 사용한다. erase와 write는
[INSTALL.md](INSTALL.ko.md)의 주소, 길이, 왕복 비교 절차를 모두 만족한 뒤에만
사용한다.

이 U-Boot의 TFTP 동작은 인자 수에 따라 방향이 달라진다.

~~~~text
tftp RAM_ADDRESS FILENAME
    server에서 RAM으로 download

tftp RAM_ADDRESS FILENAME LENGTH
    RAM에서 server로 LENGTH만큼 upload
~~~~

upload가 File not found 또는 global write permission 오류로 실패하면 TFTP
server에 mode 0666인 빈 대상 파일을 먼저 만든다.

## CramFS의 vboot

영구 boot CramFS에는 파일 세 개만 들어 있다.

~~~~text
uImage   custom Linux Legacy image + appended K75 DTB
initrd   raw gzip-compressed newc initramfs
vboot    version-bootm-patch.bin
~~~~

저장된 Debian boot 명령은 다음과 같다.

~~~~text
cramfsload 0x84000000 initrd;
cramfsload 0x82000000 uImage;
cramfsload 0x8dc33e20 vboot;
version 0x82000000
~~~~

hook 자체는 CramFS에 저장되지만 U-Boot command table의 변경은 매 부팅 때
RAM에서 다시 일어난다.

## cold boot가 처음 실패했던 이유

<code>setenv default 'run debian'</code>과 <code>saveenv</code>만 실행했을
때는 reset 후 vendor 초기화 코드가 <code>default</code>를 다시 다음
문자열로 덮어썼다.

~~~~text
cramfsload 0x82000000 uImage;
~~~~

그래서 새 environment가 정상 저장됐어도 순정 uImage만 읽은 뒤 RSA 실패와
upgrade prompt로 돌아갔다. 문제는 saveenv 실패가 아니라 vendor가 boot
중에 값을 재설정하는 고정 문자열이었다.

## 장비별 persistent autoboot patch

고정 문자열은 SPI offset <code>0x00040000</code>에서 시작하는 64 KiB
sector에 있다. <code>debian/build-uboot-autoboot-patch.py</code>는 보드에서
직접 읽은 sector를 입력받아 다음 조건을 검사한다.

- 입력이 정확히 65,536바이트
- sector 내부 local offset <code>0x54cc</code>에 원본 command가 존재
- 원본 command가 sector에 정확히 한 번 존재
- 뒤따르는 <code>default</code>와 <code>verify</code> field가 예상값과 일치
- 변경 byte가 고정 command field 밖으로 나가지 않음

검사를 통과하면 command field만 NUL padding한
<code>run debian</code>으로 바꾼다. sector에는 MAC, 보정값이나 build별
데이터가 포함될 수 있으므로 반드시 같은 대상 장비에서 읽은 sector로
patch를 생성한다.

environment에는 다음 두 변수만 저장한다.

~~~~text
debian=cramfsload 0x84000000 initrd;cramfsload 0x82000000 uImage;cramfsload 0x8dc33e20 vboot;version 0x82000000
default=run debian
~~~~

vendor routine은 persistent sector 변경 뒤부터 매 부팅 때
<code>default=run debian</code>을 설정하고, environment의
<code>debian</code> 명령을 실행한다.

## bring-up용 legacy 파일

<code>debian/ram-loader/loader.S</code>,
<code>debian/build-ram-loader.sh</code>와
<code>debian/build-spi-boot-bundle.py</code>는 RSA wrapper, cache/MMU와
kernel entry를 조사하던 초기 bring-up 기록이다. 현재 설치 경로에서는
사용하지 않는다.

## 적용 제한

- handler 주소가 맞는지 U-Boot binary를 직접 분석하지 않은 다른 build에는
  적용하지 않는다.
- 12바이트 patch를 U-Boot 저장 영역에 직접 기록하지 않는다.
- RAM patch가 RSA 설정 전체나 secure boot 상태를 영구 변경한다고 가정하지
  않는다.
- full SPI backup과 UART/TFTP 복구 수단 없이 persistent sector를 쓰지 않는다.
