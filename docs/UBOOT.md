# U-Boot `version` Hook Internals

**English** | [한국어](UBOOT.ko.md)

This document records behavior verified on the exact Hikvision U-Boot build
<code>2010.06-svn33219 (May 15 2019 - 19:24:05)</code>. The RAM and function
addresses below do not apply to another U-Boot build, firmware build, or
Hi3536DV100 board.

## Why the hook is needed

The commands displayed by this U-Boot do not behave the same way as its vendor
boot path:

- Running <code>bootm</code> directly invokes Hikvision RSA verification first.
  <code>setenv verify n</code> does not affect that check.
- <code>sf</code> appears in help, but direct execution can be blocked by the
  security filter.
- <code>cramfsload</code> is not in the ordinary command table. It is handled
  by the vendor default routine's dispatcher, so invoking it through a normal
  <code>run bootcmd</code> path can produce an Unknown command error.

Changing only the mutable fields of a U-Boot command entry in RAM allows an
existing internal handler to be invoked through the permitted
<code>version</code> command name. This does not modify stored U-Boot code. A
reset or power cycle removes the RAM hook.

## The 12-byte command-entry patch

On this build, <code>0x8dc33e20</code> is the address of three 32-bit
little-endian fields in the live <code>version</code> command entry:

~~~~text
offset +0x00: maxargs
offset +0x04: repeatable
offset +0x08: command handler pointer
~~~~

The name, usage, and help pointers are unchanged. The generator creates these
tuples:

| Output | maxargs | repeatable | Handler | Purpose |
|---|---:|---:|---:|---|
| <code>version-bootm-patch.bin</code> | 4 | 1 | <code>0x8dc12360</code> | U-Boot <code>do_bootm</code> |
| <code>version-sf-patch.bin</code> | 5 | 1 | <code>0x8dc1532c</code> | SPI flash handler |
| <code>version-mainloop-patch.bin</code> | 1 | 1 | <code>0x8dc19e44</code> | Normal U-Boot main loop test |
| <code>version-defaultboot-patch.bin</code> | 1 | 1 | <code>0x8dd041b8</code> | Vendor default routine test |

Generate them locally:

~~~~sh
python3 debian/ram-loader/make_abort_patch.py
~~~~

Only the bootm and sf patches are required for production installation. The
mainloop and defaultboot patches were used during bring-up to test the cold
boot path in RAM.

## Using the RAM boot handler

~~~~text
tftp 0x84000000 initramfs-debian.cpio.gz
tftp 0x82000000 uImage-debian-k75-docker-bridge
tftp 0x8dc33e20 version-bootm-patch.bin
version 0x82000000
~~~~

The Legacy uImage header records the fixed RAM range for the appended K75 DTB
and initramfs. The handler verifies the Legacy checksum and starts the kernel.

## Using the SPI handler

~~~~text
tftp 0x8dc33e20 version-sf-patch.bin
version probe 0
version read 0x82000000 0x00000000 0x01000000
~~~~

Confirm that the probe reports
<code>16384 KiB hi_fmc at 0:0 is now current device</code>. Use read operations
for backup and verification first. Use erase and write only after completing
all address, length, and round-trip comparison checks in
[INSTALL.md](INSTALL.md).

On this U-Boot build, the number of TFTP arguments determines transfer
direction:

~~~~text
tftp RAM_ADDRESS FILENAME
    download from the server to RAM

tftp RAM_ADDRESS FILENAME LENGTH
    upload LENGTH bytes from RAM to the server
~~~~

If an upload fails with File not found or a global write permission error,
create an empty mode-0666 destination file on the TFTP server first.

## The CramFS `vboot` file

The persistent boot CramFS contains only three files:

~~~~text
uImage   custom Linux Legacy image + appended K75 DTB
initrd   raw gzip-compressed newc initramfs
vboot    version-bootm-patch.bin
~~~~

The stored Debian boot command is:

~~~~text
cramfsload 0x84000000 initrd;
cramfsload 0x82000000 uImage;
cramfsload 0x8dc33e20 vboot;
version 0x82000000
~~~~

The hook file is stored in CramFS, but the U-Boot command-table modification
is applied in RAM again on every boot.

## Why the first cold boot failed

After only
<code>setenv default 'run debian'</code> and <code>saveenv</code>, vendor
initialization code replaced <code>default</code> with this string during the
next boot:

~~~~text
cramfsload 0x82000000 uImage;
~~~~

The new environment had been saved correctly, but the device loaded only the
stock uImage, failed RSA verification, and returned to the upgrade prompt. The
problem was the fixed command string applied by the vendor boot code, rather
than a failure of <code>saveenv</code>.

## Per-device persistent autoboot patch

The fixed string is located in the 64 KiB sector beginning at SPI offset
<code>0x00040000</code>.
<code>debian/build-uboot-autoboot-patch.py</code> accepts a sector read
directly from the target board and verifies all of these conditions:

- The input is exactly 65,536 bytes.
- The original command is present at local sector offset
  <code>0x54cc</code>.
- The original command occurs exactly once in the sector.
- The following <code>default</code> and <code>verify</code> fields contain
  the expected values.
- No changed byte lies outside the fixed command field.

After validation, the generator replaces only that command field with the
NUL-padded string <code>run debian</code>. Always generate the patch from the
sector read from the same target device because it can contain a MAC address,
calibration values, or build-specific data.

Only these two environment variables are saved:

~~~~text
debian=cramfsload 0x84000000 initrd;cramfsload 0x82000000 uImage;cramfsload 0x8dc33e20 vboot;version 0x82000000
default=run debian
~~~~

After the persistent sector change, the vendor routine sets
<code>default=run debian</code> during every boot and executes the
<code>debian</code> command from the environment.

## Legacy bring-up files

<code>debian/ram-loader/loader.S</code>,
<code>debian/build-ram-loader.sh</code>, and
<code>debian/build-spi-boot-bundle.py</code> preserve early bring-up work used
to investigate the RSA wrapper, cache/MMU state, and kernel entry. The current
installation path does not use them.

## Compatibility limits

- Do not use these addresses with another build unless its U-Boot binary has
  been analyzed and the handler addresses have been verified.
- Do not write the 12-byte patch directly into the stored U-Boot region.
- Do not assume that the RAM patch permanently changes the complete RSA
  configuration or secure-boot state.
- Do not write the persistent sector without a full SPI backup and working
  UART/TFTP recovery path.
