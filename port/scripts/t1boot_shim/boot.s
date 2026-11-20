! =====================================================================
! Shim that shadows verif/diag/assembly/include/boot.s.
!
! The legacy boot chain (boot.s -> hboot.s -> config.m4/constants.h/
! defines.h/macros.m4 ...) relies on the midas assembler's SECTION /
! attr_text / attr_data directives and m4 macros, so it cannot be
! assembled with GNU binutils.  port/scripts/build_diag.py puts this
! directory first on the cpp -I path so `#include "boot.s"` resolves
! here and the diag is instead driven by the minimal GNU-as boot
! harness port/scripts/t1boot_min.s.
! =====================================================================
#include "t1boot_defines.h"
