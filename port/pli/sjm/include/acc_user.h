// Minimal VCS acc_user.h replacement for the Icarus Verilog VPI port.
// Implemented in port/pli/sjm/tfacc_vpi.cc on top of the IEEE 1364 VPI API.
#ifndef FAKE_ACC_USER_H
#define FAKE_ACC_USER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void *handle;

// acc_set_value formats (values arbitrary, must match tfacc_vpi.cc).
#define accBinStrVal  1
#define accHexStrVal  2
#define accStringVal  3
#define accIntVal     4

// acc_set_value delay models.
#define accNoDelay    1

typedef struct t_setval_value {
    int format;
    union {
        char *str;
        int   integer;
    } value;
} s_setval_value, *p_setval_value;

typedef struct t_setval_delay {
    int model;
    int low, high, real;   /* unused padding, VCS layout not needed */
} s_setval_delay, *p_setval_delay;

void   acc_initialize(void);
void   acc_close(void);
handle acc_handle_tfarg(int n);
char  *acc_fetch_value(handle h, char *fmt, void *unused);
void   acc_set_value(handle h, s_setval_value *vp, s_setval_delay *dp);

#ifdef __cplusplus
}
#endif

#endif
