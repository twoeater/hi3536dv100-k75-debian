/* SPDX-License-Identifier: GPL-2.0-only */
OUTPUT_ARCH(arm)
ENTRY(_start)

SECTIONS
{
    . = 0x81000000;
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
    }
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.ARM.attributes)
    }
}
