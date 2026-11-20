/* Linker script for the minimal T1 diag build (see t1boot_min.s header). */
ENTRY(Power_On_Reset)
SECTIONS
{
  /* RED page: trap table + boot body (PA = VA[39:0] per tb_core_smoke) */
  . = 0xfffff0000000;
  .vectors : { *(.vectors) }
  .boot    : { *(.boot) }

  /* Diag main text / data / thread_status_mem (MMU off: VA == PA).
     These sit inside the RED IO window (PA[39]=1) rather than down at
     0x10000000: the cmp_top env answers only the uncached IO fetch, and a
     jump to a cacheable DRAM address (PA[39]=0) goes through the L2, whose
     way-select is still X in this bring-up (L2_DATA_ERR).  Keeping the diag
     in the IO window lets the boot responder serve it directly.  The
     tb_diag path is unaffected - it serves every PA from the same image.
     .text may be large, so .data/.bss follow it; thread_status_mem is
     pinned well clear of the trap table and boot body. */
  . = 0xfffff0010000;
  .text : { *(.text*) }
  .data : { *(.data*) *(.rodata*) }
  .bss  : { *(.bss) }
  . = 0xfffff0020000;
  .tstatus : { *(.tstatus*) }
}
