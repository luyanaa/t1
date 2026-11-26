#define THREAD_MASK 0x1
	.section .text
	.global main
main:
	set	buf, %o0
	sethi	%hi(0x12345000), %g2
	or	%g2, 0x678, %g2
	stx	%g2, [%o0]
	membar	#Sync
	ldx	[%o0], %g3
	cmp	%g3, %g2
	bne	bad
	 nop
	ta	0x00
	 nop
bad:	ta	0x01
	 nop
	.align 8
buf:	.word 0,0
