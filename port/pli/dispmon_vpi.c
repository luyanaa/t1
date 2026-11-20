/*
 * dispmon_vpi.c - minimal VPI shim for the CoverMeter "$dispmon" system task.
 *
 * WHY THIS EXISTS
 * ---------------
 * The OpenSPARC T1 RTL contains 124 unguarded `$dispmon(...)` calls
 * (CoverMeter coverage-monitor hooks, e.g.
 * design/sys/iop/jbi/jbi_min/rtl/jbi_min_parse.v:546).  The source files
 * are read-only and are annotated with `// synopsys translate_off`
 * pragmas, which Icarus Verilog ignores entirely.  As a result vvp
 * fails at load time with "System task/function $dispmon() is not
 * defined by any module" on all 124 call sites ("Program not runnable,
 * 124 errors") and the simulation never starts.
 *
 * VPI modules are the only way to define unknown system tasks in
 * Icarus, so this shim registers `$dispmon` via vpi_register_systf.
 *
 * SCOPE: DISPLAY-ONLY NO-OP.  This is NOT the Sun SJM/tfacc PLI
 * emulation (see port/pli/sjm).  It exists purely to unblock
 * elaboration.  If the `+dispmon` plusarg is given, each systf
 * argument is evaluated (vpi_get_value) and printed vpi_printf-style
 * so any debug info in the monitor calls survives; without the
 * plusarg the call is a strict no-op.
 *
 * BUILD:
 *   iverilog-vpi --name=dispmon port/pli/dispmon_vpi.c
 *   (run from repo root; it emits dispmon.vpi/.o in the CWD — move both
 *    into port/pli as dispmon.vpi and dispmon.vpl)
 *
 * USE:
 *   vvp -M port/pli -m dispmon port/build/cmp_top.vvp
 *   (add +dispmon to enable the display output)
 */

#include <stdio.h>
#include <string.h>
#include <vpi_user.h>

/* Evaluate and print each argument of the $dispmon call, $display-style. */
static void dispmon_print_args(void)
{
    vpiHandle callh = vpi_handle(vpiSysTfCall, 0);
    vpiHandle argv = vpi_iterate(vpiArgument, callh);
    vpiHandle arg;
    s_vpi_value val;
    int first = 1;

    if (argv == NULL)
        return;

    while ((arg = vpi_scan(argv)) != NULL) {
        /* Try a decimal-formatted string first; strings themselves and
         * any format vpi_get_value can't render as decimal fall back to
         * the raw string form. */
        val.format = vpiDecStrVal;
        vpi_get_value(arg, &val);
        if (val.format == vpiDecStrVal) {
            vpi_printf("%s%s", first ? "" : " ", val.value.str);
        } else {
            val.format = vpiObjTypeVal;
            vpi_get_value(arg, &val);
            if (val.format == vpiStringVal || val.format == vpiBinStrVal ||
                val.format == vpiOctStrVal || val.format == vpiHexStrVal)
                vpi_printf("%s%s", first ? "" : " ", val.value.str);
            else
                vpi_printf("%s<arg>", first ? "" : " ");
        }
        first = 0;
    }
    vpi_printf("\n");
}

/* True if the +dispmon plusarg was passed on the vvp command line. */
static int dispmon_plusarg_present(void)
{
    s_vpi_vlog_info info;
    int i;

    if (vpi_get_vlog_info(&info) != 1)
        return 0;
    for (i = 0; i < info.argc; i++) {
        if (info.argv[i] && strcmp(info.argv[i], "+dispmon") == 0)
            return 1;
    }
    return 0;
}

static PLI_INT32 dispmon_calltf(PLI_BYTE8 *user_data)
{
    (void)user_data;

    /* Strict display no-op unless the +dispmon plusarg is present. */
    if (dispmon_plusarg_present())
        dispmon_print_args();

    return 0;
}

static void dispmon_register(void)
{
    s_vpi_systf_data tf;

    tf.type = vpiSysTask;
    tf.tfname = "$dispmon";
    tf.calltf = dispmon_calltf;
    tf.compiletf = 0;
    tf.sizetf = 0;
    tf.user_data = 0;
    vpi_register_systf(&tf);
}

void (*vlog_startup_routines[])(void) = { dispmon_register, 0 };
