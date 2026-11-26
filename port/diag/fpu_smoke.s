! =====================================================================
! FPU smoke test for the minimal T1 port harness.
!
! The TB (tb_diag.v built with -DFPU_SMOKE) instantiates the real shared
! FPU (design/sys/iop/fpu/rtl/fpu.v) and routes PCX request types 5'h0a /
! 5'h0b to it; every other request still goes to the memory responder.
! So this diag really executes FP instructions end to end:
!
!   wr %fprs  -> FPRS.fef = 1
!   wr %pstate -> PSTATE.pef = 1     (both are required: ifu fpen_s)
!   ldd  -> LSU load + fpop packet that writes the FP register file
!   faddd / fsubd / fmuld -> FPU arithmetic, result stays in the FPU
!   fstd -> FPU returns the 64-bit value over CPX, core stores it
!   ld   -> check the stored double word by word
!
! One status word per thread (all threads, when THREADS=4, compute their
! own result from a per-thread operand).
!
!   make -C port fpu-smoke            # SMT/FPU from the environment
!   make -C port fpu-smoke SMT=4 FPU=1
! =====================================================================

#define THREAD_MASK 0xf

! FPRS.FEF is bit 2, PSTATE.PEF is bit 4.
#define FPRS_FEF	4
#define PSTATE_PEF	0x10

	.section .text
	.global main
main:
	wr	%g0, FPRS_FEF, %fprs		! enable the FP register file
	rdpr	%pstate, %g1
	or	%g1, PSTATE_PEF, %g1
	wrpr	%g1, 0, %pstate		! enable FP in PSTATE

	th_fork(fp_t)

fp_t_0:
	set	fp_tid0, %o0
	ba	fp_run
	 nop
fp_t_1:
	set	fp_tid1, %o0
	ba	fp_run
	 nop
fp_t_2:
	set	fp_tid2, %o0
	ba	fp_run
	 nop
fp_t_3:
	set	fp_tid3, %o0
	ba	fp_run
	 nop

! %o0 = address of this thread's operand block:
!   [0]  double A
!   [8]  double B
!   [16] expected A+B
!   [24] expected A-B
!   [32] expected A*B
fp_run:
	ldd	[%o0 + 0], %f0
	ldd	[%o0 + 8], %f2

	faddd	%f0, %f2, %f4
	std	%f4, [%o0 + 40]
	ld	[%o0 + 40], %g3
	ld	[%o0 + 16], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop
	ld	[%o0 + 44], %g3
	ld	[%o0 + 20], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop

	fsubd	%f0, %f2, %f4
	std	%f4, [%o0 + 48]
	ld	[%o0 + 48], %g3
	ld	[%o0 + 24], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop
	ld	[%o0 + 52], %g3
	ld	[%o0 + 28], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop

	fmuld	%f0, %f2, %f4
	std	%f4, [%o0 + 56]
	ld	[%o0 + 56], %g3
	ld	[%o0 + 32], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop
	ld	[%o0 + 60], %g3
	ld	[%o0 + 36], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop

	! fmovd must keep the value (register-to-register path in the FPU)
	fmovd	%f4, %f6
	std	%f6, [%o0 + 64]
	ld	[%o0 + 64], %g3
	ld	[%o0 + 32], %g5
	cmp	%g3, %g5
	bne	fp_bad
	 nop

fp_good:
	ta	0x00			! T_GOOD_TRAP
	 nop
fp_bad:
	ta	0x01			! T_BAD_TRAP
	 nop

	.section .data
	.align	8

! thread 0: 3.0 + 2.0 = 5.0, 1.0, 6.0
fp_tid0:
	.word	0x40080000, 0x00000000		! 3.0
	.word	0x40000000, 0x00000000		! 2.0
	.word	0x40140000, 0x00000000		! 5.0
	.word	0x3ff00000, 0x00000000		! 1.0
	.word	0x40180000, 0x00000000		! 6.0
	.word	0x00000000, 0x00000000		! fadd result slot
	.word	0x00000000, 0x00000000		! fsub result slot
	.word	0x00000000, 0x00000000		! fmul result slot
	.word	0x00000000, 0x00000000		! fmov result slot

! thread 1: 1.5 + 2.5 = 4.0, -1.0, 3.75
fp_tid1:
	.word	0x3ff80000, 0x00000000		! 1.5
	.word	0x40040000, 0x00000000		! 2.5
	.word	0x40100000, 0x00000000		! 4.0
	.word	0xbff00000, 0x00000000		! -1.0
	.word	0x400e0000, 0x00000000		! 3.75
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000

! thread 2: 0.5 + 0.25 = 0.75, 0.25, 0.125
fp_tid2:
	.word	0x3fe00000, 0x00000000		! 0.5
	.word	0x3fd00000, 0x00000000		! 0.25
	.word	0x3fe80000, 0x00000000		! 0.75
	.word	0x3fd00000, 0x00000000		! 0.25
	.word	0x3fc00000, 0x00000000		! 0.125
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000

! thread 3: 1024.0 + 1.0 = 1025.0, 1023.0, 1024.0
fp_tid3:
	.word	0x40900000, 0x00000000		! 1024.0
	.word	0x3ff00000, 0x00000000		! 1.0
	.word	0x40900400, 0x00000000		! 1025.0
	.word	0x408ff800, 0x00000000		! 1023.0
	.word	0x40900000, 0x00000000		! 1024.0
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000000
