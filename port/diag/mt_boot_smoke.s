! =====================================================================
! Multi-thread boot smoke test for the minimal T1 port harness.
!
! Every thread that comes out of reset runs boot_main -> main.  th_fork
! asks the trap handler for the running thread id and branches to that
! thread's label, so this diag only completes if all four threads really
! execute.  Each thread then takes `ta T_GOOD_TRAP`, whose handler writes
! a one-hot thread word to thread_status_mem; the testbench waits for all
! started threads before deciding (tb_diag.v +threads=N).
!
!   make -C port diag-run DIAG=port/diag/mt_boot_smoke.s THREADS=4
!
! THREAD_MASK must match the number of threads started by the testbench,
! otherwise the extra threads fall through to T_BAD_TRAP.
! =====================================================================

#define THREAD_MASK 0xf

	.section .text
	.global main
main:
	th_fork(mt_label)
	ta	0x01			! T_BAD_TRAP: TID not in THREAD_MASK

mt_label_0:
	ba	mt_done
	 nop
mt_label_1:
	ba	mt_done
	 nop
mt_label_2:
	ba	mt_done
	 nop
mt_label_3:
	ba	mt_done
	 nop

mt_done:
	ta	0x00			! T_GOOD_TRAP -> proc_good_trap
	 nop
