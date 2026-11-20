/* Minimal subset of verif/diag/assembly/include/defines.h
 * (legacy trap service numbers), for the GNU-as diag build.
 * Only the service-trap constants that appear in direct-style diags
 * are reproduced; anything else from defines.h is a blocker and must
 * be added here (see build_diag.py report). */

#define T_GOOD_TRAP			        0x00
#define T_BAD_TRAP			        0x01
#define T_CHANGE_PRIV    		        0x02
#define T_CHANGE_NONPRIV    		        0x03
#define T_CHANGE_TO_TL1 		        0x04
#define T_CHANGE_TO_TL0 		        0x05
#define T_TRAP_EN                               0x08
#define T_TRAP_DIS                              0x0a
#define T_TRAP_EN_N_TIMES                       0x0c
#define T_MUTEX_LOCK                            0x10
#define T_MUTEX_UNLOCK                          0x14
#define T_SYNC                                  0x16
#define T_FUNCTION                              0x18
#define T_SYSCALL                               0x18
#define T_SYSRET                                0x1a
#define T_CHANGE_HPRIV    		        0x20
#define T_CHANGE_NONHPRIV    		        0x22
#define T_HTRAP_EN                              0x24
#define T_HTRAP_DIS                             0x26
#define T_HTRAP_EN_N_TIMES                      0x28
#define T_CHANGE_CTX				0x2a
#define T_RD_THID				0x2e
#define T_TRAP_INST0                            0x30
#define T_TRAP_INST1                            0x31
#define T_HTRAP_INST0                           0x32
#define T_HTRAP_INST1                           0x33

#define T_API_CHANGE_PRIV    		        0x80
#define T_API_CHANGE_NONPRIV   		        0x82
#define T_API_TRAP_EN                           0x84
#define T_API_TRAP_DIS                          0x86
#define T_API_TRAP_EN_N_TIMES                   0x88
#define T_API_CHANGE_CTX			0x8a
#define T_API_RD_THID				0x8e
#define T_API_HTRAP_INST0			0x90
#define T_API_HTRAP_INST1			0x91
#define T_API_RD_THID_GLOBAL			0x96
