! Core-level FP smoke: no memory traffic at all, just FP instructions that must
! traverse the FFU -> PCX -> FPU -> CPX -> FRF path and retire without a trap.
#define THREAD_MASK 0x1
	.section .text
	.global main
main:
	wr	%g0, 4, %fprs
	rdpr	%pstate, %g1
	or	%g1, 0x10, %g1
	wrpr	%g1, 0, %pstate
	faddd	%f0, %f2, %f4
	fmuld	%f4, %f2, %f6
	fdivd	%f6, %f2, %f8
	fsubd	%f8, %f2, %f10
	ta	0x00
	 nop
