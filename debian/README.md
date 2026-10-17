# Debian Build Tools for Hi3536DV100 K75

**English** | [한국어](README.ko.md)

This directory contains tools for building a Debian root filesystem and boot
images locally for the K75 board. The kernel source is fetched at build time
from a pinned OpenIPC Linux commit.

Read these documents before starting:

- [Source preparation and builds](../docs/BUILD.md)
- [UART testing and installation](../docs/INSTALL.md)
- [U-Boot hook internals](../docs/UBOOT.md)

## Recommended build order

~~~~sh
./debian/prepare-kernel-source.sh
./debian/build-rootfs.sh --clean
./debian/build-boot-images.sh
./debian/build-docker-bridge-images.sh
python3 ./debian/ram-loader/make_abort_patch.py
sudo ./debian/build-msata-root-image.sh
~~~~

Connect the input file using the name documented in
[vendor/README.md](../vendor/README.md). All results are created under
<code>debian/build/</code> and <code>debian/out/</code>, both of which are
excluded from Git.

## Production path

| File | Purpose | Storage changes |
|---|---|---|
| <code>prepare-kernel-source.sh</code> | Creates the validated source tree from pinned OpenIPC Linux, the local patch, and Kconfig fragments | None |
| <code>build-rootfs.sh</code> | Creates a Debian Bookworm ARMHF rootfs tarball | None |
| <code>build-boot-images.sh</code> | Extracts the K75 DTB and a stock uImage copy for local validation from user-supplied firmware | None |
| <code>build-docker-bridge-images.sh</code> | Builds the kernel, modules, initramfs, uImage, and 4 MiB SPI CramFS in sequence | None |
| <code>build-initramfs.sh</code> | Creates the BusyBox root-switch initramfs and ext4 modules | None |
| <code>package-debian-k75.sh</code> | Updates the K75 DTB and creates the appended-DTB Legacy uImage and boot hook | None |
| <code>build-spi-cramfs.py</code> | Packs uImage, initrd, and vboot into little-endian CramFS with FF padding | None |
| <code>build-msata-root-image.sh</code> | Creates the partition-level ext4 rootfs image and swapfile | Uses a loop mount; does not modify a physical disk |
| <code>build-uboot-autoboot-patch.py</code> | Changes only the command field in a 64 KiB sector from the user's device | Creates an output file only |
| <code>ram-loader/make_abort_patch.py</code> | Generates RAM-only command-entry patches for the exact U-Boot build | None |
| <code>verify-docker-kernel.sh</code> | Tests cgroups, overlayfs, bridge/veth, and netfilter at runtime | Creates and then removes temporary interfaces and a mount |

Commands that modify an actual mSATA partition or SPI NOR are intentionally
excluded from the build scripts. The user runs each destructive step in
[INSTALL.md](../docs/INSTALL.md) after checking UART output and readback data.

## Configuration and source patch

<code>kernel-configs/k75-boot.config</code> configures early UART and modular
ext4. <code>kernel-configs/docker-bridge.config</code> adds devtmpfs, cgroups,
seccomp, overlayfs, bridge/veth, netfilter, and legacy iptables support.

<code>kernel-patches/0001-hi3536dv100-k75-boot-fixes.patch</code> contains
the minimal source changes verified during K75 boot. The base tree with
HiSilicon SoC support is fetched from the exact OpenIPC commit. Its source is
neither copied into this repository nor registered as a Git submodule.

## initramfs

<code>initramfs/init</code> performs these steps:

1. Mounts proc, sysfs, run, and devtmpfs.
2. Uses tmpfs and BusyBox mdev on test vendor kernels without devtmpfs.
3. Sets standard character-device modes to 0666.
4. Loads mbcache, jbd2, and ext4 modules in order when they are present.
5. Searches for a block device matching
   <code>digicap.root_transport</code> on the kernel command line.
6. Verifies the <code>.digicap-debian-root</code> marker on the ext4
   filesystem.
7. Moves dev, proc, sys, and run, then uses switch_root to start firstboot or
   SysV init.

Supported transport values are <code>sata</code>, <code>usb</code>, and
<code>any</code>. The production uImage uses <code>sata</code>.

## Debian overlay

The <code>overlay/</code> directory contains only:

- Debian Bookworm apt sources
- Hostname and hosts configuration
- A DHCP network interface
- Basic SSH configuration
- SysV firstboot
- A <code>policy-rc.d</code> file that prevents services from starting while
  the root filesystem is being built

Firstboot runs the second debootstrap stage and prompts for the Debian user
password over UART. After success, it removes itself and switches to SysV
init.

## Alternative rootfs installation tool

<code>install-rootfs.sh</code> is an alternative path that installs the
rootfs tarball directly into an already mounted, empty ext4 partition. It asks
the user to re-enter the exact mount point and rejects the root filesystem or
a nonempty target.

For ordinary reproduction and installation, use
<code>build-msata-root-image.sh</code> to create a partition image.

## Bring-up records

These files preserve early investigation and recovery work but are not used
by the current installation path:

- <code>build-ram-loader.sh</code>
- <code>ram-loader/loader.S</code> and <code>loader.ld</code>
- <code>build-spi-boot-bundle.py</code>

This path was used to determine the kernel entry, cache/MMU state, and raw SPI
layout. New installations should follow the production CramFS path.

## Output overwrite policy

Most scripts do not overwrite an existing source tree or image. Before
rebuilding, identify the input that produced the existing result, then remove
the relevant subdirectory under <code>debian/build/</code> or
<code>debian/out/</code> manually. No clean target automatically removes
vendor input, SPI backups, or physical block-device data.
