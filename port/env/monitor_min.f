# port/env/monitor_min.f - Icarus Verilog port of the cmp_top-level PASS/FAIL
# monitor (de-SAS'd, derived from verif/env/cmp/monitor.v + pc_cmp.v).
#
# Self-contained: no helper files, no header includes (THRFSM_HALT and the
# trap-net names are defined inline; see the header comment in monitor_min.v).
# The XMRs inside monitor_min.v (cmp_top.iop.sparcN.tlu.*,
# cmp_top.iop.sparcN.ifu.swl.thrfsmT.thr_state) resolve against the design
# files already present in the cmp_top compile (core1_rtl.f) - the monitor
# module itself must simply be added to that flist:
#
#   /shared/t1/port/env/monitor_min.v
#
# Stubs (documented in monitor_min.v header): $bw_good_trap/$bw_sas_send/
# $sas_client/$x_checker/$check_mon/$writemon/$initmon/$dispmon_status/
# $enable_errwarnmon/$disable_errwarnmon/$ModuleStart/$ModuleEnd/
# $ModulesDone/$GetModules/$parse(PLI) are all removed or replaced; sas_def
# is hard-coded to 0.
port/env/monitor_min.v
