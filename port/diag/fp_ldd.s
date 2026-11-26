! Variant: enable FP, two ldd, no FP arithmetic (isolates the load path).
! store the result and compare it with the expected double, then trap.
! Used with tb_diag.v -DFPU_SMOKE +pcxtrace to look at the PCX traffic.

#define THREAD_MASK 0x1

	.section .text
	.global main
main:
	wr	%g0, 4, %fprs			! FPRS.FEF = 1
	rdpr	%pstate, %g1
	or	%g1, 0x10, %g1
	wrpr	%g1, 0, %pstate			! PSTATE.PEF = 1

	set	fp_data, %o0
	ldd	[%o0 + 0], %f0
	ldd	[%o0 + 8], %f2

	! no FP arithmetic: does ldd alone complete?

	ta	0x00				! T_GOOD_TRAP
	 nop
fp_bad:
	ta	0x01				! T_BAD_TRAP
	 nop

	.section .data
	.align	8
fp_data:
	.word	0x40080000, 0x00000000		! 3.0
	.word	0x40000000, 0x00000000		! 2.0
	.word	0x40140000, 0x00000000		! expected 5.0
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000		! spare
	.word	0x00000000, 0x00000000		! fadd result slot (+40)
	.word	0x00000000, 0x00000000
