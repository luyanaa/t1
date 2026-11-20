// Minimal VCS veriuser.h replacement for the Icarus Verilog VPI port.
// Only declares what the untouched SJM engine sources reference.
#ifndef FAKE_VERIUSER_H
#define FAKE_VERIUSER_H

#ifdef __cplusplus
extern "C" {
#endif

// mc_scan_plusargs is provided by the shim (tfacc_vpi.cc), which scans the
// simulator command line for +name[=value...] plusargs.
char *mc_scan_plusargs(char *name);

// tf_ family used elsewhere in the old tree; provided for completeness.
int   tf_getp(int n);
void  tf_putp(int n, int value);
char *tf_getcstringp(int n);
char *tf_strgettime(void);
int   tf_nump(void);
int   tf_typep(int n);
int   tf_dofinish(void);
int   tf_dostop(void);

#ifdef __cplusplus
}
#endif

#endif

// Legacy constants the 2006-era code assumed came from the vendor headers.
#ifndef TRUE
#define TRUE  1
#endif
#ifndef FALSE
#define FALSE 0
#endif
#ifndef null
#define null NULL
#endif

// TF misc reason codes (only reason_finish is used by sjm_misc).
#ifndef reason_finish
#define reason_finish 1
#endif
