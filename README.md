# Debian on HiSilicon Hi3536DV100 K75

**English** | [한국어](README.ko.md)

This is an unofficial board port for running Debian 12 Bookworm ARMHF on the
Hikvision K75 platform. It has been validated on a Hikvision DS-E04NI-Q1 with
PCB revision <code>80578_P REV1.0</code>. The Linux kernel and initramfs are
loaded from a CramFS image in the 16 MiB SPI NOR, while the Debian root
filesystem is mounted from mSATA.

This project is not a universal firmware image for every Hi3536DV100 device.
Boards that share the same SoC can still differ in DRAM, PHY, GPIO, storage
wiring, DTB, and U-Boot behavior.

## Compatibility

| Item | Validated value |
|---|---|
| SoC | HiSilicon Hi3536DV100, ARMv7 Cortex-A7 |
| Product | Hikvision DS-E04NI-Q1 |
| PCB | <code>80578_P REV1.0</code> |
| DT model | <code>HIKVISON K75 Platform Board</code> |
| U-Boot | <code>2010.06-svn33219 (May 15 2019 - 19:24:05)</code> |
| RAM | 256 MiB, <code>mem=256M</code> |
| Boot storage | 4 MiB CramFS region in 16 MiB SPI NOR |
| Root filesystem | First ext4 partition on mSATA |
| Console | PL011 3.3 V TTL, 115200 8N1 |

The following features have been verified on real hardware:

- Linux 4.9.37, Debian 12 Bookworm ARMHF, and SysV init
- All 256 MiB of RAM detected; <code>memtester 200M 1</code> passed
- SATA 3.0 Gbps, NCQ depth 31, ext4, and a 512 MiB swapfile
- Ethernet DHCP, USB, SSH, apt, and hardware reboot
- Automatic boot after both warm reset and complete power removal
- devtmpfs with standard device modes of 0666
- Kernel support for cgroups, overlayfs, bridge, veth, bridge netfilter, and
  legacy iptables

HDMI output, camera input, video encoding, and HiSilicon MPP acceleration have
not been implemented.

## What this repository provides

This repository contains source code and tools for producing images locally:

- A kernel preparation script that checks out the pinned
  [OpenIPC Linux Hi3536DV100 tree](https://github.com/OpenIPC/linux/tree/hisilicon-hi3536dv100)
  and applies the K75 patch and validated configuration
- Small K75-specific kernel fixes and validated Kconfig fragments
- Scripts for building the Debian root filesystem, initramfs, legacy uImage,
  and SPI CramFS image
- Patch generators that temporarily hook the <code>version</code> command in
  RAM on the exact supported U-Boot build
- A generator that creates an autoboot sector from the U-Boot sector read from
  the individual target device
- Procedures for pre-installation RAM boot testing and post-installation
  Docker kernel feature verification

The kernel source is fetched at build time from the exact OpenIPC commit
recorded in [THIRD_PARTY.md](THIRD_PARTY.md). Keep the user-supplied Hikvision
firmware outside the repository and expose it through the local symbolic link
described in [vendor/README.md](vendor/README.md).

## Source and license

This repository is licensed under GPL-2.0-only; see [LICENSE](LICENSE). The
kernel preparation step currently pins OpenIPC Linux commit
<code>6b8ca794ec3e1e35ee260377443a6a729df27e91</code>. The checked-out kernel keeps
its own copyright notices and <code>COPYING</code>, and the changes made by this
project are kept as a separate patch. See [THIRD_PARTY.md](THIRD_PARTY.md) for
source provenance.

## Boot flow

~~~~text
Hikvision U-Boot vendor default routine
  -> default=run debian
  -> SPI CramFS: initrd -> RAM 0x84000000
  -> SPI CramFS: uImage -> RAM 0x82000000
  -> SPI CramFS: 12-byte version hook -> RAM 0x8dc33e20
  -> version 0x82000000
  -> Linux 4.9.37 + appended K75 DTB
  -> initramfs locates .digicap-debian-root on SATA
  -> switch_root starts Debian from mSATA
~~~~

The procedure does not overwrite the complete U-Boot image or place the
kernel in the SPI bootloader region. Persistent changes are limited to the
existing SPI CramFS region and the per-device 64 KiB sector that contains the
vendor default command string.

## Documentation

1. [External input setup](vendor/README.md)
2. [Source preparation and image builds](docs/BUILD.md)
3. [UART RAM testing and permanent installation](docs/INSTALL.md)
4. [U-Boot <code>version</code> hook internals](docs/UBOOT.md)
5. [Script index](debian/README.md)

The detailed documents are available in English by default, with a Korean
translation linked at the top of each page.

## Safety rules

Before changing SPI or mSATA, make sure that the U-Boot prompt is accessible
over UART. Boot every new kernel and initramfs from RAM through TFTP before
writing them permanently. Before writing, read and save the entire 16 MiB SPI
flash, upload the downloaded data back through TFTP, and compare it with the
original. After writing, compare an SPI readback at the file level as well.

Never reuse a full SPI dump or patched 64 KiB sector from another device. The
partitioning, <code>dd</code>, SPI erase, and SPI write commands in the
installation guide destroy target data. The user must run them only after
checking the model, capacity, address, length, and SHA-256 at each step.

## Validation status

Boot behavior has been validated on hardware, and the kernel preparation path
has been reproduced from the pinned OpenIPC source commit. The board DTB is
extracted locally during the build from firmware supplied by the user.
