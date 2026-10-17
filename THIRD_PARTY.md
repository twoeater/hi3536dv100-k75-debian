# Third-party source provenance

## Linux kernel for Hi3536DV100

- Project: [OpenIPC Linux](https://github.com/OpenIPC/linux)
- Branch: `hisilicon-hi3536dv100`
- Pinned commit: `6b8ca794ec3e1e35ee260377443a6a729df27e91`
- Commit tree: `963b855dcab5f0d0dedffe2fd09649c6944659cc`
- Kernel version: Linux 4.9.37
- License: GPL-2.0-only, as stated by the kernel tree's `COPYING` file

`debian/prepare-kernel-source.sh` fetches this exact commit into an ignored
local build directory. It then applies
`debian/kernel-patches/0001-hi3536dv100-k75-boot-fixes.patch` and the two
tracked Kconfig fragments.

The OpenIPC branch contains the HiSilicon Hi3536DV100 enablement originally
added in [OpenIPC/linux commit 5e4e3155e7ab17df15f75662187b1b5edb83450a](https://github.com/OpenIPC/linux/commit/5e4e3155e7ab17df15f75662187b1b5edb83450a).

## Debian root filesystem and BusyBox

The build scripts download Debian Bookworm ARMHF packages from the configured
Debian repositories. Those packages retain their individual licenses and
copyright files. In a locally generated root filesystem they can be inspected
under `/usr/share/doc/*/copyright`; corresponding Debian source packages are
available through Debian's package infrastructure.

The generated initramfs copies the BusyBox binary and its applets from that
locally built Debian root filesystem. BusyBox retains its own GPL-2.0 license.

Build-host programs such as Git, GCC, GNU binutils, U-Boot `mkimage`, QEMU,
`dtc`, `mkfs.cramfs`, and `debootstrap` are invoked as tools.

## Hikvision board firmware

A firmware file supplied by the owner of the target K75 device is used as a
local input for extracting that board's DTB.
