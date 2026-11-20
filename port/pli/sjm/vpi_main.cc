//==============================================================================
//
// OpenSPARC T1 VPI port: systf registration (vpi_main.cc)
//
// Registers all 19 $sjm_* system tasks listed in verif/.../sjm/c/jbus.tab as
// Icarus Verilog VPI system tasks. The calltf bodies are the untouched
// front_* / sjm_get_* routines from verif/.../sjm/c/main.cc, pulled in below
// with #include and driven through the TF/acc shim in tfacc_vpi.cc.
//
// The VCS misc=sjm_misc reason_finish hook is replaced by a
// cbEndOfSimulation callback that calls tidy_up() on every registered master.
//
//==============================================================================

#include <cstring>
#include <cstdio>
#include <cstdlib>

#include "vpi_user.h"

// main.cc calls dprintf(unit, tag, flags, ...) directly (the VCS-era
// logger).  Rename it to the sjm_dprintf implementation in tfacc_vpi.cc,
// same as the engine compile flags do.
void sjm_dprintf(const char *mod_name, ...);
#define dprintf sjm_dprintf

// Pull in the original PLI front-end. Globals (g_masters, g_nummasters, ...)
// and all front_*/sjm_get_* calltf bodies, plus helpers (get_memq,
// get_trans_string, find_*, get_device_info) come from here.
#include "main.cc"   // open-source port copy (PlusArg overflow fix)

//------------------------------------------------------------------------------

// Thin wrappers matching the VPI calltf signature (PLI_INT32 (*)(PLI_BYTE8 *)).
#define WRAP(fn) \
  static PLI_INT32 vpi_##fn(PLI_BYTE8 *user_data) \
  { (void) user_data; acc_initialize(); fn(); acc_close(); return 0; }

WRAP(front_init)
WRAP(front_assert_pwr)
WRAP(front_assert_por)
WRAP(front_deassert_por)
WRAP(front_start_exec)
WRAP(front_get_status)
WRAP(front_set_inputs)
WRAP(front_get_outputs)
WRAP(sjm_get_infsm)
WRAP(sjm_get_arbiter)
WRAP(sjm_get_snp_ctrl)
WRAP(sjm_get_snoopq)
WRAP(sjm_get_resultsq)
WRAP(sjm_get_jpackq)
WRAP(sjm_get_jpackoutq)
WRAP(sjm_get_memq)
WRAP(sjm_get_iomemq)
WRAP(sjm_get_dataq)
WRAP(sjm_get_readbuff)
WRAP(sjm_get_outq)
WRAP(sjm_get_rdrq)
WRAP(sjm_get_out_state)

//------------------------------------------------------------------------------

// Registered task table (name, calltf). Note: Icarus requires the "$" prefix
// in the registered tfname.
#define N_TASK "$"
static struct { const char *vname; PLI_INT32 (*calltf)(PLI_BYTE8 *); } sjm_tasks[] = {
  { N_TASK"sjm_init",         vpi_front_init          },
  { N_TASK"sjm_assert_pwr",   vpi_front_assert_pwr    },
  { N_TASK"sjm_assert_por",   vpi_front_assert_por    },
  { N_TASK"sjm_deassert_por", vpi_front_deassert_por  },
  { N_TASK"sjm_start_exec",   vpi_front_start_exec    },
  { N_TASK"sjm_get_status",   vpi_front_get_status    },
  { N_TASK"sjm_set_inputs",   vpi_front_set_inputs    },
  { N_TASK"sjm_get_outputs",  vpi_front_get_outputs   },
  { N_TASK"sjm_get_infsm",    vpi_sjm_get_infsm       },
  { N_TASK"sjm_get_arbiter",  vpi_sjm_get_arbiter     },
  { N_TASK"sjm_get_snp_ctrl", vpi_sjm_get_snp_ctrl    },
  { N_TASK"sjm_get_snoopq",   vpi_sjm_get_snoopq      },
  { N_TASK"sjm_get_resultsq", vpi_sjm_get_resultsq    },
  { N_TASK"sjm_get_jpackq",   vpi_sjm_get_jpackq      },
  { N_TASK"sjm_get_jpackoutq",vpi_sjm_get_jpackoutq   },
  { N_TASK"sjm_get_memq",     vpi_sjm_get_memq        },
  { N_TASK"sjm_get_iomemq",   vpi_sjm_get_iomemq      },
  { N_TASK"sjm_get_dataq",    vpi_sjm_get_dataq       },
  { N_TASK"sjm_get_readbuff", vpi_sjm_get_readbuff    },
  { N_TASK"sjm_get_outq",     vpi_sjm_get_outq        },
  { N_TASK"sjm_get_rdrq",     vpi_sjm_get_rdrq        },
  { N_TASK"sjm_get_out_state",vpi_sjm_get_out_state   },
};
#define N_SJM_TASKS (sizeof(sjm_tasks) / sizeof(sjm_tasks[0]))

//------------------------------------------------------------------------------

// Replacement for the VCS misc=sjm_misc reason_finish hook: run tidy_up() on
// all masters at the end of simulation.
static PLI_INT32 sjm_end_of_sim_cb(p_cb_data cb_data)
{
  (void) cb_data;
  extern SJM *g_masters[G_MAX_MASTERS];
  for (int i = 0; i < G_MAX_MASTERS; i++) {
    if (g_masters[i] != NULL) {
      g_masters[i]->tidy_up();
      g_masters[i] = NULL;
    }
  }
  return 0;
}

//------------------------------------------------------------------------------

static PLI_INT32 sjm_no_compiletf(PLI_BYTE8 *user_data)
{
  (void) user_data;
  return 0;
}

static PLI_INT32 sjm_func_size(PLI_BYTE8 *user_data)
{
  (void) user_data;
  return 32; // integer-width return value
}

static void register_sjm_tasks(void)
{
  int nreg = 0;
  for (unsigned i = 0; i < N_SJM_TASKS; i++) {
    s_vpi_systf_data tf;
    tf.type      = vpiSysTask;
    tf.tfname    = (PLI_BYTE8 *) sjm_tasks[i].vname;
    tf.calltf    = sjm_tasks[i].calltf;
    tf.compiletf = sjm_no_compiletf;
    tf.sizetf    = NULL;
    tf.user_data = NULL;
    if (vpi_register_systf(&tf) != NULL) {
      nreg++;
    } else {
      vpi_printf("SJM VPI ERROR: failed to register $%s\n", sjm_tasks[i].vname);
    }
    // The legacy RTL front end (verif/env/iss/pli/sjm/rtl/sjm.v) calls the
    // $sjm_* PLIs in *function* style ("temp = $sjm_assert_por(j_id);"),
    // which VCS allowed.  Icarus requires each name to also be registered
    // as a system function for those call sites to elaborate.
    tf.type      = vpiSysFunc;
    tf.sysfunctype = vpiIntFunc;
    tf.sizetf    = sjm_func_size;
    if (vpi_register_systf(&tf) == NULL) {
      vpi_printf("SJM VPI ERROR: failed to register $%s as function\n",
                 sjm_tasks[i].vname);
    }
  }
  vpi_printf("SJM VPI: registered %d/$19 $sjm_* tasks\n", nreg);

  // End-of-simulation cleanup (replaces sjm_misc/reason_finish).
  s_cb_data cb;
  s_vpi_time  t;
  t.type = vpiSimTime; t.high = 0; t.low = 0;
  cb.reason      = cbEndOfSimulation;
  cb.cb_rtn      = sjm_end_of_sim_cb;
  cb.obj         = NULL;
  cb.time        = &t;
  cb.value       = NULL;
  cb.index       = 0;
  cb.user_data   = NULL;
  vpi_register_cb(&cb);
}

// Icarus Verilog scans the vlog_startup_routines table in the .vpl (declared
// in vpi_user.h as void (*vlog_startup_routines[])(void)). All registration
// happens from this table; vvp does not call a vpi_main_N symbol.
static void sjm_startup(void) { register_sjm_tasks(); }

extern "C" void (*vlog_startup_routines[2])(void) = { sjm_startup, 0 };
