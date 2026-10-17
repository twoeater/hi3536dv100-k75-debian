# External board input

The kernel source is fetched automatically from the exact OpenIPC commit
listed in [THIRD_PARTY.md](../THIRD_PARTY.md).

Provide firmware for the compatible K75 device through this symbolic link:

~~~~sh
ln -s /absolute/path/digicap.dav vendor/hikvision-k75.dav
~~~~

`debian/build-boot-images.sh` uses this file locally to extract and validate
the <code>HIKVISON K75 Platform Board</code> DTB.

A build can use a different firmware location with
<code>FIRMWARE=/path/to/digicap.dav</code>.
