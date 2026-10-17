#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build RAM-only U-Boot command-table patches and the ARM trampoline."""

import struct
from pathlib import Path


output_dir = Path(__file__).resolve().parent.parent / "out" / "boot"
output_dir.mkdir(parents=True, exist_ok=True)

(output_dir / "abort-patch.bin").write_bytes(
    struct.pack("<II", 0xE51FF004, 0x81000000)
)
(output_dir / "version-patch.bin").write_bytes(struct.pack("<I", 0x81000000))

# Replace only the mutable fields in the live ``version`` command entry:
#   maxargs=4, repeatable=1, cmd=do_bootm
# This keeps its name/usage pointers intact while allowing
# ``version <kernel> <ramdisk> <fdt>`` to enter U-Boot's normal bootm path.
(output_dir / "version-bootm-patch.bin").write_bytes(
    struct.pack("<III", 4, 1, 0x8DC12360)
)

# Route the allowed ``version`` command to U-Boot's existing ``sf`` handler.
# This is a RAM-only proxy for boards whose command-name security filter turns
# direct ``sf`` invocations into no-ops.  Use it with read-only subcommands as
# ``version probe 0`` and ``version read <addr> <offset> <length>``.
(output_dir / "version-sf-patch.bin").write_bytes(
    struct.pack("<III", 5, 1, 0x8DC1532C)
)

# Enter this exact U-Boot build's main_loop through the allowed ``version``
# command.  main_loop reads ``bootdelay`` and ``bootcmd`` itself and invokes
# run_command() directly, so this reproduces cold autoboot without saveenv or
# a reset.  It is useful for testing a candidate bootcmd entirely in RAM.
(output_dir / "version-mainloop-patch.bin").write_bytes(
    struct.pack("<III", 1, 1, 0x8DC19E44)
)

# Enter Hikvision's outer/default boot routine through ``version``.  Unlike
# U-Boot main_loop, this routine uses the vendor command table containing
# cramfsload: it reads the ``default`` environment value, runs it directly,
# and then attempts ``bootm 0x82000000``.  This provides a RAM-only rehearsal
# of the path used during a real cold boot before committing the environment.
(output_dir / "version-defaultboot-patch.bin").write_bytes(
    struct.pack("<III", 1, 1, 0x8DD041B8)
)
