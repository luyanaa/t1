! =====================================================================
! Minimal GNU-as port of the OpenSPARC T1 diag boot harness
! (replacement for the midas-only verif/diag/assembly/include/boot.s
!  -> hboot.s chain, which uses SECTION/attr_text/m4 directives that
!  GNU binutils cannot assemble).
!
! Memory map (all PA == VA, MMU is left OFF; single-thread, part 0):
!   VA/PA 0xfffff0000000 : trap vector table.
!                          Hardware traps: tt = 0x00..0xff ->
!                            vector = TBA + tt*0x20 (0x0000..0x1ff0).
!                            POR/RST (tt 0x02) lands at TBA+0x40
!                            -> PA 0xfff0000040, matching tb_core_smoke.v.
!                          Software `ta N` traps: tt = 0x100+N ->
!                            vector = TBA + 0x2000 + N*0x20.
!   VA/PA 0xfffff0004000 : boot body + good/bad trap handlers
!                          (.vectors is 0x200 slots x 0x20 = 0x4000).
!   VA/PA 0x10000000     : diag .text
!   VA/PA 0x10001000     : diag .data/.bss
!   VA/PA 0x10020000     : thread_status_mem (one-hot PASS/FAIL word)
!
! Provided `ta` services (trap numbers N from defines.h, tt = 0x100+N).
! Verified working end-to-end on tb_diag, DIAG PASS on:
!   tlu_tick_read_1, tlu_multi_intl_00, tlu_multi_intl_01
!   (reset -> boot_main -> main -> ta services -> ta 0 -> status store -> PASS)
! Caveats:
!   - th_fork() expands via build_diag.py (ta 0x2e rdth_id + cmp/be).
!   - NC fetch (POR/ITLB-off) makes every instruction an IMISS; sim is slow
!     (~8 misses per 32B line) but functionally correct.
!   - Diags needing real trap handlers (irf_ce, pic_ovfl, data-access-error)
!     hit SLOT_BAD -> FAIL; they need the full legacy env, not this shim.
!   0x00 T_GOOD_TRAP       -> one-hot TID written to thread_status_mem,
!                             upper32=0 (pass), then halt (wr %asr26,0x1).
!   0x01 T_BAD_TRAP        -> same, upper32=0xf (fail), then halt.
!   0x02 T_CHANGE_PRIV     -> set priv bit in saved %tstate, done.
!   0x03 T_CHANGE_NONPRIV  -> clear priv bit in saved %tstate, done.
!   0x04 T_CHANGE_TO_TL1   -> set TL=1 in %tl, done.
!   0x05 T_CHANGE_TO_TL0   -> clear %tl, done.
!   0x20 T_CHANGE_HPRIV    -> set priv in tstate + htstate=4, done.
!   0x22 T_CHANGE_NONHPRIV -> clear priv in tstate, done
!                             (htstate left untouched: writing 0 here
!                              makes `done` lose the fetch redirect).
!   0x24 T_HTRAP_EN        -> no-op stub, done.
!   0x26 T_HTRAP_DIS       -> no-op stub, done.
!   0x2a T_CHANGE_CTX      -> no-op stub, done.
!   0x2e T_RD_THID         -> thread id (0..3) in %o1, done.
!   0x30 T_TRAP_INST0      -> install custom handler slot0, done.
!   0x31 T_TRAP_INST1      -> install custom handler slot1, done.
!   0x30 T_SEND_THRD_INTR  -> (my_intr_handlers.s) same slot as INST0;
!                             we route it to a stub that does `done`.
!                             Diags needing real intr delivery must use
!                             the full legacy env.
!   everything else        -> proc_bad_trap (FAIL).
!
! After the POR slot jumps to boot_main, boot_main installs
! %tba/%htba, clears hpstate.RED (else every trap vectors to RSTV
! 0x40, not %tba), drops %tl from MAXTL to 0 (else `ta` overflows
! back into reset), and initialises the TL0 state fields
! (%cwp/%gl/%pstate/%ccr/%asi) so a `ta` saves a clean tstate and
! `done` can restore one without X bits.  It then jumps to `main`
! (no `done` needed at TL0).
! =====================================================================

	.section .vectors, "ax"
	.global Power_On_Reset

! ----------------------------------------------------------------------
! Hardware trap region  (tt = 0x00 .. 0xff, offset = tt*0x20)
! ----------------------------------------------------------------------

	.macro SLOT_BAD
	ba	proc_bad_trap
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	.endm

! Load a symbol address into \rd as a *sign-extended* 64-bit value.
!
! A plain `setx` of an address in the RED IO window (0xfffffxxxxxxxxx)
! produces 0x0000FFFFxxxxxxxx: bit 47 is set but bits 63:48 are zero.
! sparc_exu_alu_16eql (design/.../sparc_exu_alu.v:184) checks that
! va_e[63:47] are all equal; a mixed value sets exu_ifu_va_oor_m, which
! (via fcl set_oor_m -> pc_oor_vec) raises INST_ACC_EXC (tt 0x08) on the
! next fetch, and the same check faults load/store addresses.  Direct
! `ba` branches are immune because their target is derived from the
! already sign-extended PC; only register addresses (setx/jmp, mem ops)
! need this.  OR in 0xFFFF000000000000 to make the value canonical.
	.macro SETXVA sym, tmp, rd
	 setx	\sym, \tmp, \rd
	 mov	-1, \tmp
	 sllx	\tmp, 48, \tmp
	 or	\rd, \tmp, \rd
	.endm

	! tt 0x00 (offset 0x00): reserved
	SLOT_BAD

	! tt 0x01 (offset 0x20): the cmp_top env's reset fetch lands HERE,
	! not at tt 0x02.  The TLU reset PC is RSTVADDR_BASE<<13 | {ttype,5'b0}
	! (tlu_tcl.v) and the IFU consumes it one slot early, so the first
	! IMISS is PA 0xfff0000020.  Branch to boot_main from this slot too;
	! the tb_diag path (which fetches 0x40) is unaffected.
	ba	boot_main
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! tt 0x02 (offset 0x40): POR/RST physical fetch slot
Power_On_Reset:
	ba	boot_main
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! tt 0x03 .. 0xff : unhandled -> FAIL
	.rept	0xfd
	SLOT_BAD
	.endr

! ----------------------------------------------------------------------
! Software `ta` region  (tt = 0x100+N, offset = 0x2000 + N*0x20)
! We are currently at offset 0x2000 (= start of tt 0x100).
! ----------------------------------------------------------------------

	! ---- tt 0x100 : T_GOOD_TRAP (N=0x00) ------------------------------
	ba	proc_good_trap
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x101 : T_BAD_TRAP (N=0x01) -------------------------------
	ba	proc_bad_trap
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x102 : T_CHANGE_PRIV (N=0x02) ----------------------------
	rdpr	%tstate, %g1
	 or	%g1, 0x400, %g1
	 wrpr	%g1, 0, %tstate
	 done
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x103 : T_CHANGE_NONPRIV (N=0x03) -------------------------
	rdpr	%tstate, %g1
	 andn	%g1, 0x400, %g1
	 wrpr	%g1, 0, %tstate
	 done
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x104 : T_CHANGE_TO_TL1 (N=0x04) --------------------------
	rdpr	%tl, %g1
	 or	%g0, 1, %g2
	 wrpr	%g2, 0, %tl
	 done
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x105 : T_CHANGE_TO_TL0 (N=0x05) --------------------------
	wrpr	%g0, 0, %tl
	 done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! tt 0x106 .. 0x11f : unhandled -> FAIL
	.rept	0x1a
	SLOT_BAD
	.endr

	! ---- tt 0x120 : T_CHANGE_HPRIV (N=0x20) ---------------------------
	! Do NOT rdhpr/or/wrhpr: the TSA htstate field is uninitialised at
	! POR, so rdhpr returns X and the or/wrhpr would store X back.
	! Write an absolute htstate (bit2 = HPRIV) instead, via the XOR-imm
	! form:  %g0(0) XOR 0x4 = 0x4.
	rdpr	%tstate, %g1
	 or	%g1, 0x400, %g1
	 wrpr	%g1, 0, %tstate
	 wrhpr	%g0, 0x4, %htstate
	 done
	 nop
	 nop
	 nop

	! ---- tt 0x121 : unhandled -----------------------------------------
	SLOT_BAD

	! ---- tt 0x122 : T_CHANGE_NONHPRIV (N=0x22) ------------------------
	! Clear priv in the saved tstate only; leave htstate untouched so
	! `done` restores a known-good value.
	rdpr	%tstate, %g1
	 andn	%g1, 0x400, %g1
	 wrpr	%g1, 0, %tstate
	 done
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x123 : unhandled -----------------------------------------
	SLOT_BAD

	! ---- tt 0x124 : T_HTRAP_EN (N=0x24) : stub done -------------------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x125 : unhandled -----------------------------------------
	SLOT_BAD

	! ---- tt 0x126 : T_HTRAP_DIS (N=0x26) : stub done ------------------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! tt 0x127 .. 0x129 : unhandled -> FAIL
	.rept	3
	SLOT_BAD
	.endr

	! ---- tt 0x12a : T_CHANGE_CTX (N=0x2a) : stub done -----------------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! tt 0x12b .. 0x12d : unhandled -> FAIL
	.rept	3
	SLOT_BAD
	.endr

	! ---- tt 0x12e : T_RD_THID (N=0x2e) --------------------------------
	rd	%asr26, %o1
	 srl	%o1, 0x8, %o1
	 and	%o1, 0x3, %o1
	 done
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x12f : unhandled -----------------------------------------
	SLOT_BAD

	! ---- tt 0x130 : T_TRAP_INST0 / T_SEND_THRD_INTR (N=0x30) ----------
	! Stub: install nothing, just `done` so the diag continues.  A real
	! T_TRAP_INST0 would patch the trap table; diags needing it use the
	! full legacy env.  T_SEND_THRD_INTR also lands here (N=0x30); we
	! just ack it by returning.
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x131 : T_TRAP_INST1 / T_SEND_CPU_MONDO_Q (N=0x31) --------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x132 : T_HTRAP_INST0 / T_SEND_DEV_MONDO_Q (N=0x32) -------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x133 : T_HTRAP_INST1 / T_SEND_RES_ERROR_Q (N=0x33) -------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! ---- tt 0x134 : T_SEND_SOFTINT (N=0x34) : stub done ---------------
	done
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop
	 nop

	! tt 0x135 .. 0x1ff : unhandled -> FAIL
	.rept	(0x200 - 0x135)
	SLOT_BAD
	.endr

! =====================================================================
! boot body + service handlers  (PA 0xfffff0000800 area; linked via
! .boot section placed right after .vectors in t1boot.ld)
! =====================================================================
	.section .boot, "ax"
	.global boot_main
boot_main:
	setx	0xfffff0000000, %g1, %g2
	 wrpr	%g2, 0, %tba
	 wrhpr	%g2, 0, %htba
	! Exit RED state (else every trap vectors to RSTV 0x40, not %tba)
	! hpstate: red=0, enb=1  (matches hred_reset_handler.s:170)
	 rdhpr	%hpstate, %l1
	 wrhpr	%l1, 0x820, %hpstate
	! POR leaves %tl = MAXTL; any `ta`/trap would overflow back into
	! reset.  Drop to TL0 like hred_reset_handler.s:262 (wrpr 0,%tl).
	 wrpr	%g0, 0, %tl
	! Initialise the TL0 execution state fields so a `ta` saves a clean
	! tstate and `done` restores one.  At TL0 the per-field registers
	! must be written individually (wrpr %tstate only updates TSA[tl],
	! which done does not read at TL0).
	 wrpr	%g0, 0, %cwp			! cwp = 0
	 wrpr	%g0, 0, %gl			! gl  = 0 (global reg set)
	 mov	0x16, %g1			! pstate IE|PRIV|PEF (bit1|2|4)
	 wrpr	%g1, 0, %pstate
	 wr	%g0, 0, %ccr			! ccr = 0
	 wr	%g0, 0x80, %asi			! asi = ASI_PRIMARY
	! Jump straight to main; we are privileged, non-RED, TL0.
	 SETXVA	main, %g1, %g2
	 jmp	%g2
	 nop

	.align 32
	.global proc_good_trap
proc_good_trap:
	rd %asr26, %g1
	srl %g1, 0x8, %g1	! Shift & Mask
	and %g1, 0x3, %g1	! Thread ID
	or %g0, 0x1, %g3
	sll %g3, %g1, %g3	! One-hot Thread

	SETXVA thread_status_mem, %g1, %g2
	stx %g3, [%g2]		! Zero in upper 32 bits indicates success

1:	rd %asr26, %g1
	wr %g1, 0x1, %asr26	! Halt
	nop
	ba 1b
	 nop

	.align 32
	.global proc_bad_trap
proc_bad_trap:
	rd %asr26, %g1
	srl %g1, 0x8, %g1	! Shift & Mask
	and %g1, 0x3, %g1	! Thread ID
	or %g0, 0x1, %g3
	sll %g3, %g1, %g3	! One-hot Thread

	or %g0, 0xf, %g4	! Fail Status
	sllx %g4, 0x20, %g4
	or %g3, %g4, %g4	! Fail status in top 32 bits, TID mask
	SETXVA thread_status_mem, %g1, %g2
	stx %g4, [%g2]

2:	rd %asr26, %g1
	wr %g1, 0x1, %asr26	! Halt
	nop
	ba 2b
	 nop

! =====================================================================
! thread_status_mem (one-hot word, read by the testbench)
! =====================================================================
	.section .tstatus, "aw"
	.global thread_status_mem
	.align 8
thread_status_mem:
	.xword	0x0000000000000000
