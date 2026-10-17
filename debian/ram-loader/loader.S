/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Minimal Hi3536DV100 Linux hand-off for U-Boot's `go` command.
 *
 * The loader may be entered either as a standalone application or through
 * U-Boot's writable exception vector.  It first switches from the exception
 * mode to SVC mode, then cleans the ARMv7 caches, disables IRQ/FIQ, MMU and
 * caches, installs the Linux boot protocol registers, and jumps to the raw
 * zImage without invoking bootm's vendor RSA/noinitrd policy.
 */

	.syntax unified
	.cpu cortex-a7
	.arm

	.equ UART0_BASE,  0x12080000
	.equ UART_DR,     0x00
	.equ UART_FR,     0x18
	.equ UART_TXFF,   0x20
	.equ MACH_HI3536D, 8000
	.equ KERNEL_ADDR, 0x86000000
	.equ DTB_ADDR,    0x85000000

	.section .text.start, "ax", %progbits
	.align 5
	.global _start
	.type _start, %function
_start:
	/* A data-abort vector enters in ABT mode; Linux requires SVC mode. */
	mrs	r0, cpsr
	bic	r0, r0, #0x1f
	orr	r0, r0, #0xd3
	msr	cpsr_c, r0
	ldr	r0, =loader_message
	bl	uart_puts

	/* Preserve the Linux entry values. */
	ldr	r8, =MACH_HI3536D
	ldr	r9, =DTB_ADDR
	ldr	r10, =KERNEL_ADDR

	/*
	 * This vendor U-Boot runs with its data cache disabled and flushes each
	 * TFTP destination itself.  A full set/way walk hangs on this secure
	 * Cortex-A7 setup, so follow the vendor cleanup_before_linux path and
	 * only turn the caches/MMU off here.
	 */
	ldr	r0, =loader_stage_cleanup
	bl	uart_puts

	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	/* invalidate instruction cache */
	mcr	p15, 0, r0, c7, c5, 6	/* invalidate branch predictor */
	mcr	p15, 0, r0, c8, c7, 0	/* invalidate unified TLB */
	dsb
	isb

	mrc	p15, 0, r3, c1, c0, 0
	bic	r3, r3, #(1 << 12)		/* instruction cache */
	bic	r3, r3, #(1 << 2)		/* data cache */
	bic	r3, r3, #1			/* MMU */
	mcr	p15, 0, r3, c1, c0, 0
	dsb
	isb

	ldr	r0, =loader_stage_control_off
	bl	uart_puts

	ldr	r0, =loader_stage_jump
	bl	uart_puts
	mov	r0, #0
	mov	r1, r8
	mov	r2, r9
	bx	r10

1:	b	1b
	.size _start, . - _start

	.type uart_puts, %function
uart_puts:
	push	{r1-r3, lr}
	ldr	r1, =UART0_BASE
1:	ldrb	r2, [r0], #1
	cmp	r2, #0
	beq	3f
2:	ldr	r3, [r1, #UART_FR]
	tst	r3, #UART_TXFF
	bne	2b
	str	r2, [r1, #UART_DR]
	b	1b
3:	pop	{r1-r3, pc}
	.size uart_puts, . - uart_puts

/* ARMv7 clean-and-invalidate of every data/unified cache set and way. */
	.type flush_dcache_all, %function
flush_dcache_all:
	push	{r0-r7, r9-r12, lr}
	dmb
	mrc	p15, 1, r0, c0, c0, 1	/* CLIDR */
	ands	r3, r0, #0x07000000
	mov	r3, r3, lsr #23		/* LoC aligned for comparison */
	beq	5f
	mov	r10, #0
1:	add	r2, r10, r10, lsr #1
	mov	r1, r0, lsr r2
	and	r1, r1, #7
	cmp	r1, #2
	blt	4f
	mcr	p15, 2, r10, c0, c0, 0	/* CSSELR */
	isb
	mrc	p15, 1, r1, c0, c0, 0	/* CCSIDR */
	and	r2, r1, #7
	add	r2, r2, #4
	ldr	r4, =0x3ff
	ands	r4, r4, r1, lsr #3
	clz	r5, r4
	ldr	r7, =0x7fff
	ands	r7, r7, r1, lsr #13
2:	mov	r9, r4
3:	orr	r11, r10, r9, lsl r5
	orr	r11, r11, r7, lsl r2
	mcr	p15, 0, r11, c7, c14, 2
	subs	r9, r9, #1
	bge	3b
	subs	r7, r7, #1
	bge	2b
4:	add	r10, r10, #2
	cmp	r3, r10
	bgt	1b
5:	mov	r10, #0
	mcr	p15, 2, r10, c0, c0, 0
	dsb
	isb
	pop	{r0-r7, r9-r12, pc}
	.size flush_dcache_all, . - flush_dcache_all

	.align 2
loader_message:
	.asciz "\r\nRAM loader v2: entered\r\n"
loader_stage_cleanup:
	.asciz "L1: cache/MMU cleanup\r\n"
loader_stage_control_off:
	.asciz "L2: cache/MMU off\r\n"
loader_stage_jump:
	.asciz "L3: jumping to Linux zImage\r\n"
