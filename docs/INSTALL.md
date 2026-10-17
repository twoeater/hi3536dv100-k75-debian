# UART RAM Testing and Permanent Installation

**English** | [한국어](INSTALL.ko.md)

This procedure has been validated only on the following combination:

- Hikvision DS-E04NI-Q1
- PCB <code>80578_P REV1.0</code>
- HiSilicon Hi3536DV100 K75
- U-Boot <code>2010.06-svn33219 (May 15 2019 - 19:24:05)</code>
- 16 MiB SPI NOR

Stop if any address or U-Boot handler differs. Establish a working UART
recovery path, TFTP upload, and a full SPI backup before changing the SPI
flash.

The partitioning, <code>dd</code>, SPI erase, and SPI write commands in this
document destroy target data. Do not paste the procedure as one batch. The
user must run each destructive step separately after checking the preceding
verification result.

## 1. Verify the artifacts and prepare TFTP

After completing the local build in [BUILD.md](BUILD.md), verify the hash
manifests first:

~~~~sh
cd debian/out/boot-docker-bridge
sha256sum -c DEBIAN_BOOT-docker-bridge_SHA256SUMS
cd ../msata-image
sha256sum -c digicap-debian-msata-rootfs.sha256
~~~~

Do not create a file named exactly <code>uImage</code> in the TFTP root,
because that is the name requested by the existing automatic boot path. Keep
the explicit test name:

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

Use <code>192.0.0.128/24</code> for the TFTP host, matching the default U-Boot
environment. The board uses <code>192.0.0.64</code>.

## 2. Write the mSATA root filesystem

First inspect the model, capacity, transport, and mount state:

~~~~sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,FSTYPE,MOUNTPOINTS
~~~~

In the examples below, replace <code>/dev/sdX</code> with the whole target
mSATA device.

### Destructive step: replace the partition table

The following commands remove the target disk's existing partitions and data:

~~~~sh
printf 'label: dos\nunit: sectors\n\nstart=2048, type=83\n' |
  sudo sfdisk /dev/sdX
sudo partprobe /dev/sdX
~~~~

### Destructive step: write the ext4 image

This is an image for the first partition, not for the whole disk:

~~~~sh
gzip -t debian/out/msata-image/digicap-debian-msata-rootfs.ext4.gz
gzip -dc debian/out/msata-image/digicap-debian-msata-rootfs.ext4.gz |
  sudo dd of=/dev/sdX1 bs=4M conv=fsync status=progress
sudo e2fsck -f /dev/sdX1
sudo resize2fs /dev/sdX1
~~~~

Verify the result:

~~~~sh
sudo blkid /dev/sdX1
sudo e2fsck -fn /dev/sdX1
~~~~

The filesystem label defaults to <code>DIGICAP_MSATA</code>. Its UUID is
generated when the image is built and is already written into the image's
<code>/etc/fstab</code>. Use the value reported by <code>blkid</code>; it can
differ between builds.

## 3. Enter the U-Boot prompt over UART

Open the 3.3 V TTL UART at 115200 8N1 with flow control disabled. Power on the
device and press <code>Ctrl+U</code> to stop autoboot. At the upgrade question,
do not press <code>u</code>. Enter <code>b</code> to reach the
<code>HKVS #</code> prompt.

These values must match exactly:

~~~~text
HKVS # version
U-Boot 2010.06-svn33219 (May 15 2019 - 19:24:05)

HKVS # printenv
ipaddr=192.0.0.64
serverip=192.0.0.128
~~~~

## 4. Boot entirely from RAM without changing SPI

~~~~text
tftp 0x84000000 initramfs-debian.cpio.gz
tftp 0x82000000 uImage-debian-k75-docker-bridge
tftp 0x8dc33e20 version-bootm-patch.bin
version 0x82000000
~~~~

This stage does not write SPI. After Debian starts, inspect the system:

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

The important values observed on the validated device were:

~~~~text
root: /dev/sda1 ext4 rw,noatime
System RAM: 80000000-8fffffff
MemTotal: approximately 253768 kB
SATA link: 3.0 Gbps
NCQ depth: 31
/dev/null: 0666 root:root
~~~~

Test the kernel features required for Docker as well:

~~~~sh
sudo ./debian/verify-docker-kernel.sh
~~~~

The final line must be
<code>Docker bridge kernel checks: PASS</code>.

## 5. Back up the complete 16 MiB SPI flash

With this U-Boot, a third <code>tftp</code> argument is a length for uploading
from RAM to the server. Depending on the tftpd-hpa configuration, a writable
empty destination file must exist first.

Run this on the TFTP server:

~~~~sh
sudo install -m 0666 /dev/null /srv/tftp/spi-nor-full-16MiB.bin
~~~~

In U-Boot, use the RAM-only SPI hook to read and upload the flash:

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version read 0x82000000 0x00000000 0x01000000
tftp 0x82000000 spi-nor-full-16MiB.bin 0x01000000
~~~~

The probe must report:

~~~~text
16384 KiB hi_fmc at 0:0 is now current device
~~~~

On the server, confirm that the file is exactly 16,777,216 bytes and record its
hash:

~~~~sh
stat -c '%s %n' /srv/tftp/spi-nor-full-16MiB.bin
sha256sum /srv/tftp/spi-nor-full-16MiB.bin
~~~~

Keep the backup in two independent locations.

## 6. Round-trip the 4 MiB CramFS download

Create an empty upload destination on the TFTP server:

~~~~sh
sudo install -m 0666 /dev/null /srv/tftp/cramfs-preflash.bin
~~~~

Download the image into RAM in U-Boot, then upload the same 4 MiB:

~~~~text
tftp 0x82000000 k75-debian-spi-cramfs-4MiB.bin
tftp 0x82000000 cramfs-preflash.bin 0x00400000
~~~~

Compare the files on the server:

~~~~sh
cmp /srv/tftp/k75-debian-spi-cramfs-4MiB.bin \
  /srv/tftp/cramfs-preflash.bin
sha256sum /srv/tftp/k75-debian-spi-cramfs-4MiB.bin \
  /srv/tftp/cramfs-preflash.bin
~~~~

Continue only if <code>cmp</code> succeeds and both hashes match.

## 7. Write the CramFS to SPI

### Destructive step: erase and write 4 MiB at SPI 0x000a0000

These commands erase and replace
<code>0x000a0000-0x0049ffff</code> in SPI. The file verified in step 6 must
still be present in RAM:

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version erase 0x000a0000 0x00400000
version write 0x82000000 0x000a0000 0x00400000
version read 0x82000000 0x000a0000 0x00400000
~~~~

Upload the readback. First create an empty destination file on the server:

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

If the readback does not match, do not reset or power off the device. Keep the
UART session active and investigate the mismatch.

## 8. Generate the per-device autoboot sector

At every boot, vendor initialization code resets the U-Boot
<code>default</code> variable to
<code>cramfsload 0x82000000 uImage;</code>. Changing only the saved
environment therefore does not survive a cold boot. Read the sector from the
individual device and replace only that fixed string with
<code>run debian</code>.

Create the upload destination on the server:

~~~~sh
sudo install -m 0666 /dev/null \
  /srv/tftp/uboot-sector-40000-current.bin
~~~~

Read the current sector in U-Boot:

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version read 0x82000000 0x00040000 0x00010000
tftp 0x82000000 uboot-sector-40000-current.bin 0x00010000
~~~~

Run the generator on the PC:

~~~~sh
python3 debian/build-uboot-autoboot-patch.py \
  /srv/tftp/uboot-sector-40000-current.bin \
  --tftp-dir /srv/tftp
~~~~

The generator checks the length, uniqueness of the target string, exact
offset, and adjacent fields. It does not create an output if the expected
bytes differ. The output sector is specific to this device.

Round-trip the generated sector through TFTP before writing it:

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

### Destructive step: erase and write the SPI 0x00040000 sector

Run these commands only after the comparison succeeds:

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
tftp 0x82000000 uboot-sector-40000-run-debian.bin
version erase 0x00040000 0x00010000
version write 0x82000000 0x00040000 0x00010000
version read 0x82000000 0x00040000 0x00010000
~~~~

Upload the readback and compare it with the generated file:

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

## 9. Save the U-Boot environment

After the sector readback matches, run these commands in U-Boot:

~~~~text
setenv debian 'cramfsload 0x84000000 initrd;cramfsload 0x82000000 uImage;cramfsload 0x8dc33e20 vboot;version 0x82000000'
setenv default 'run debian'
saveenv
printenv default debian
~~~~

Expected values:

~~~~text
default=run debian
debian=cramfsload 0x84000000 initrd;cramfsload 0x82000000 uImage;cramfsload 0x8dc33e20 vboot;version 0x82000000
~~~~

First use <code>reset</code> to verify a warm boot. After Debian starts
normally, remove power completely, restore it, and verify a cold boot.

## 10. Verify the installed system

~~~~sh
findmnt -n -o SOURCE,FSTYPE,OPTIONS /
test ! -e /firstboot && echo FIRSTBOOT_DONE || echo FIRSTBOOT_PENDING
stat -c '%U:%G %a %n' /usr/bin/passwd /usr/bin/su /usr/bin/sudo
swapon --show
dmesg | grep -E 'ata1|sda1|NCQ|I/O error|timeout' | tail -30
~~~~

On the first boot, set the Debian user password over UART. When setup
completes, the root filesystem should be <code>/dev/sda1</code> and swap
should be <code>/swapfile</code>.

## Recovery principles

As long as autoboot can be interrupted over UART, the TFTP RAM-boot path and
RAM-only SPI hook remain available. Restore only from the full SPI backup and
original 64 KiB sector read from that same device. Do not issue a full-chip
write command until its address and length have been verified again.
