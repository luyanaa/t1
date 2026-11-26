! Minimal single-thread FP bring-up program: enable FP, build 3.0/2.0/5.0 in
! integer registers, park them in memory, ldd them back, faddd, then compare
! the double result against 5.0 with fcmpd/fbne.  No FP store (std %f,..) is
! used, so the FP arithmetic path can be validated before the FST path is.
#define THREAD_MASK 0x1

	.section .text
	.global main
main:
	wr	%g0, 4, %fprs			! FPRS.FEF = 1
	rdpr	%pstate, %g1
	or	%g1, 0x10, %g1
	wrpr	%g1, 0, %pstate			! PSTATE.PEF = 1

	set	fp_data, %o0

	sethi	%hi(0x40080000), %g2		! 3.0
	sllx	%g2, 32, %g2
	stx	%g2, [%o0 + 0]
	sethi	%hi(0x40000000), %g3		! 2.0
	sllx	%g3, 32, %g3
	stx	%g3, [%o0 + 8]
	sethi	%hi(0x40140000), %g4		! 5.0
	sllx	%g4, 32, %g4
	stx	%g4, [%o0 + 16]
	membar	#Sync

	ldd	[%o0 + 0], %f0
	ldd	[%o0 + 8], %f2
	ldd	[%o0 + 16], %f6

	faddd	%f0, %f2, %f4			! 3.0 + 2.0
	fcmpd	%f4, %f6			! must equal 5.0
	fbne	fp_bad
	 nop

	ta	0x00				! T_GOOD_TRAP
	 nop
fp_bad:
	ta	0x01				! T_BAD_TRAP
	 nop

	.section .text
	.align	8
fp_data:
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
