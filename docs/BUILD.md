# Source Preparation and Image Builds

**English** | [한국어](BUILD.ko.md)

This document explains how to build the validated kernel and Debian images
locally from pinned public kernel source and board firmware supplied by the
user.

## Build host

The validated build host is Ubuntu 24.04 x86-64 with
<code>arm-linux-gnueabi-gcc 13.3.0</code>. On Debian and Ubuntu systems, the
required tools can generally be installed with these packages:

~~~~sh
sudo apt install \
  bc binwalk bison build-essential cpio cramfsprogs debootstrap \
  debian-archive-keyring device-tree-compiler e2fsprogs fakeroot flex \
  gcc-arm-linux-gnueabi git libssl-dev patch p7zip-full python3 \
  qemu-user-static u-boot-tools xz-utils
~~~~

Package names may differ on other distributions. Each script checks its
required commands and input files before it starts.

## External input

Create one symbolic link using the name documented in
[vendor/README.md](../vendor/README.md), pointing to stock firmware for the
user's own device:

~~~~text
vendor/
└── hikvision-k75.dav -> stock firmware for the target device
~~~~

The kernel is downloaded automatically from the
<code>hisilicon-hi3536dv100</code> branch of
[OpenIPC Linux](https://github.com/OpenIPC/linux). The effective input is
pinned to this exact 40-character commit rather than the moving branch name:

~~~~text
6b8ca794ec3e1e35ee260377443a6a729df27e91
~~~~

Source and license information is recorded in
[THIRD_PARTY.md](../THIRD_PARTY.md).

## Prepare the kernel source

The following command shallow-fetches the pinned OpenIPC Linux commit and
applies the repository's K75 patch:

~~~~sh
./debian/prepare-kernel-source.sh
~~~~

The default output directory is
<code>debian/build/linux-4.9.37-hi3536dv100-k75</code>. The script does not
overwrite an existing directory.

The configuration is assembled in this order:

1. <code>hi3536dv100_full_defconfig</code> from the OpenIPC tree
2. <code>debian/kernel-configs/k75-boot.config</code>
3. <code>debian/kernel-configs/docker-bridge.config</code>
4. <code>make ARCH=arm olddefconfig</code>

The expected SHA-256 of the completed configuration is
<code>c70a0cd192257b9d12b0653ebe6d0a3a039cbd30645b2b79926ffbfa7101c096</code>.
The preparation script stops if the result differs.

The kernel patch contains only these changes:

- ARM section flag syntax accepted by current assemblers
- Removal of the duplicate <code>yylloc</code> declaration from the DTC lexer
  source, matching the generated DTC lexer fix already present in the pinned
  OpenIPC commit
- 32-bit register writes required by the K75 PL011 early UART
- SATA PHY selection at 1.5 or 3.0 Gbps from the
  <code>hisilicon,phy-mode</code> DT property

A local OpenIPC mirror and a different output directory can be selected with
environment variables. The mirror must provide the same pinned commit:

~~~~sh
OPENIPC_LINUX_REPOSITORY=/path/to/openipc-linux.git \
KERNEL_DIR=/path/to/output-kernel \
  ./debian/prepare-kernel-source.sh
~~~~

## Prepare the K75 board DTB

The K75 DTB is currently extracted locally from stock firmware owned by the
user:

~~~~sh
./debian/build-boot-images.sh
~~~~

The script locates the <code>HIKVISON K75 Platform Board</code> DTB in the
stock firmware's uImage. The generated
<code>debian/out/boot/k75.dtb</code>, decompiled DTS, and stock uImage copy are
used by subsequent local build steps.

Specify firmware in another location as follows:

~~~~sh
FIRMWARE=/path/to/device-firmware.dav \
  ./debian/build-boot-images.sh
~~~~

## Debian root filesystem

~~~~sh
./debian/build-rootfs.sh --clean
~~~~

This script creates a Debian Bookworm ARMHF minbase root filesystem with
debootstrap in foreign mode, then adds SSH, networking, SysV init, sudo,
BusyBox, and the K75 overlay. It produces these two files:

~~~~text
debian/out/debian-bookworm-armhf-rootfs.tar.gz
debian/out/debian-bookworm-armhf-rootfs.tar.gz.sha256
~~~~

On the ARM device, <code>/firstboot</code> performs the second debootstrap
stage and prompts for the user password during the first boot.

## Kernel, initramfs, uImage, and SPI CramFS

Run the following after completing the preceding three build stages:

~~~~sh
./debian/build-docker-bridge-images.sh
~~~~

The script performs these steps:

1. Merges the validated Kconfig fragments again and checks for missing options.
2. Builds the ARM zImage and kernel modules.
3. Adds the mbcache, jbd2, and ext4 modules to a BusyBox initramfs.
4. Writes 256 MiB boot arguments, the initrd range, timer clock, and SATA PHY
   mode into the K75 DTB.
5. Appends the DTB to the zImage and creates a Legacy uImage.
6. Packs the uImage, raw initramfs, and RAM-only boot hook into a 4 MiB CramFS
   image.

The principal outputs are written here:

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

The padded SPI file is exactly 4 MiB and targets
<code>0x000a0000-0x0049ffff</code>. The script does not overwrite existing
output files.

## Generate the U-Boot RAM hooks

~~~~sh
python3 debian/ram-loader/make_abort_patch.py
~~~~

Installation uses
<code>debian/out/boot/version-bootm-patch.bin</code> and
<code>debian/out/boot/version-sf-patch.bin</code>. Both are 12-byte RAM
patches and contain no SPI data. Their structure and exact compatibility
limits are described in [UBOOT.md](UBOOT.md).

## mSATA root filesystem image

~~~~sh
sudo ./debian/build-msata-root-image.sh
~~~~

The defaults create a 2 GiB ext4 filesystem image with a 512 MiB swapfile:

~~~~text
debian/out/msata-image/digicap-debian-msata-rootfs.ext4
debian/out/msata-image/digicap-debian-msata-rootfs.ext4.gz
debian/out/msata-image/digicap-debian-msata-rootfs.sha256
~~~~

This is an ext4 filesystem image for a partition, not a whole-disk image. See
[INSTALL.md](INSTALL.md) for the procedure to write it to an mSATA partition
and expand the filesystem. By default, <code>mkfs.ext4</code> generates a new
filesystem UUID and the script writes that value into the image's
<code>/etc/fstab</code>. Set <code>FILESYSTEM_UUID</code> only when a specific
UUID is required.

## Naming and reproducibility

Some file names and the root marker retain the original project name
<code>digicap</code>. They are compatibility identifiers used by the
initramfs and existing installation images. The supported target is the K75
board, not every device based on Hi3536DV100.

The kernel source commit and prepared configuration are verified against
fixed values. Final images are not guaranteed to be byte-for-byte identical
between builds because of the uImage header timestamp, the Debian archive
package versions available at build time, and filesystem creation timestamps.
Use the generated manifest and SHA-256 values for each installation.
