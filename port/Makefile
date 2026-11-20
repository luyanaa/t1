ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BUILD := $(ROOT)/port/build
TOP ?= sparc
PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
YOSYS ?= yosys
JOBS ?= $(shell nproc 2>/dev/null || echo 2)

OSS_CAD_SUITE ?= /shared/oss-cad-suite/bin
FPGA_YOSYS ?= $(if $(wildcard $(OSS_CAD_SUITE)/yosys),$(OSS_CAD_SUITE)/yosys,$(YOSYS))
NEXTPNR ?= $(OSS_CAD_SUITE)/nextpnr-himbaechel
GOWIN_PACK ?= $(OSS_CAD_SUITE)/gowin_pack
FPGA_DEVICE ?= GW5AST-LV138FPG676AC1/I0
FPGA_FAMILY ?= GW5AST-138C
FPGA_CST ?= $(ROOT)/port/fpga/tang_mega_138k.cst
# The full core reaches ~76% LUT utilization; timing-driven analytic
# placement is prohibitively slow at that density.  The heap placer is the
# cheapest legalization attempt (it can still fail at this utilisation).
FPGA_PNR_FLAGS ?= --placer heap --no-tmdriv --freq 50 --timing-allow-fail
FPGA_BUILD := $(BUILD)/fpga
ASIC_DIR := $(ROOT)/port/asic

.PHONY: all filelist icarus verilator yosys smoke smoke-verilator regress clean \
	fpga-flist fpga-sim fpga-synth fpga-pnr fpga-bitstream fpga fpga-smoke \
	asic-smoke asic-config asic-synth \
	playback playback-nop playback-simple_br playback-smoke \
	diag-build cmp-build cmp-run

all: icarus verilator yosys

# Regenerate the $readmemh L2 preload image (test l2_buf) from the C-array
# memory image in the diag firmware source. Output is committed under
# port/stim/l2_buf.mem; @addr units are 64-bit words (pa/8).
MEMIMAGE_SRC := $(ROOT)/port/firmware/mbfw_diag_memimage.c
STIM_DIR := $(ROOT)/port/stim

memimage: $(STIM_DIR)/l2_buf.mem

$(STIM_DIR)/l2_buf.mem: $(MEMIMAGE_SRC) $(ROOT)/port/scripts/memimage2hex.py
	$(PYTHON) $(ROOT)/port/scripts/memimage2hex.py \
		--src $(MEMIMAGE_SRC) --out $@

# Assemble a legacy "direct"-style diag into a $readmemh memory image for
# the open-source testbench.  Usage:
#   make -C port diag-build DIAG=verif/diag/assembly/IFU/priv_ch_dlyslt.s
# Output: port/build/diag/<name>/<name>.mem (see build_diag.py for the
# toolchain, per-diag defines and the memory map).
diag-build:
	$(PYTHON) $(ROOT)/port/scripts/build_diag.py $(DIAG)

filelist:
	@mkdir -p $(BUILD)
	$(PYTHON) $(ROOT)/port/scripts/gen_filelist.py \
		--mode rtl \
		--top $(TOP) \
		-o $(BUILD)/core1_rtl.f \
		--config-v $(BUILD)/config.v \
		--yosys $(BUILD)/core1_rtl.ys

icarus: filelist
	cd $(ROOT) && $(IVERILOG) -g2005 -s $(TOP) \
		-f $(BUILD)/core1_rtl.f \
		-o $(BUILD)/core1_rtl.vvp

verilator: filelist
	cd $(ROOT) && $(VERILATOR) --lint-only --language 1364-2001 \
		--no-timing --top-module $(TOP) -Wno-fatal \
		-f $(BUILD)/core1_rtl.f

yosys: filelist
	cd $(ROOT) && $(YOSYS) -q -s $(BUILD)/core1_rtl.ys

smoke: filelist
	cd $(ROOT) && $(IVERILOG) -g2005 -s tb_core_smoke \
		-f $(BUILD)/core1_rtl.f \
		design/sys/iop/rtl/iop_fpga.v \
		port/tb/tb_core_smoke.v \
		-o $(BUILD)/core1_smoke.vvp
	cd $(ROOT) && $(VVP) $(BUILD)/core1_smoke.vvp > $(BUILD)/smoke_icarus.log 2>&1 || \
		{ cat $(BUILD)/smoke_icarus.log; exit 1; }
	@grep -q "SMOKE PASS" $(BUILD)/smoke_icarus.log || \
		{ cat $(BUILD)/smoke_icarus.log; echo "SMOKE FAIL (Icarus)"; exit 1; }
	@cat $(BUILD)/smoke_icarus.log
	@echo "SMOKE PASS (Icarus)"

smoke-verilator: filelist
	cd $(ROOT) && $(VERILATOR) --binary --timing \
		--language 1364-2001 -Wno-fatal \
		--top-module tb_core_smoke --build-jobs $(JOBS) \
		-CFLAGS "-O0" \
		--Mdir $(BUILD)/obj_smoke -o vsmoke \
		-f $(BUILD)/core1_rtl.f \
		+define+INNO_MUXEX \
		design/sys/iop/rtl/iop_fpga.v \
		port/tb/tb_core_smoke.v
	$(BUILD)/obj_smoke/vsmoke > $(BUILD)/smoke_verilator.log 2>&1 || \
		{ cat $(BUILD)/smoke_verilator.log; exit 1; }
	@grep -q "SMOKE PASS" $(BUILD)/smoke_verilator.log || \
		{ cat $(BUILD)/smoke_verilator.log; echo "SMOKE FAIL (Verilator)"; exit 1; }
	@cat $(BUILD)/smoke_verilator.log
	@echo "SMOKE PASS (Verilator)"

regress: smoke smoke-verilator
	@echo "REGRESSION PASS (1 test, 2 simulators)"

# ---------------------------------------------------------------
# Generic diag testbench (image-driven L2 responder)
# ---------------------------------------------------------------
# Serves a $readmemh memory image (trap table + diag text/data) over PCX/CPX
# and watches thread_status_mem for the diag's PASS/FAIL result.
#   make -C port diag MEM=port/build/diag/tlu_tick_read_1.mem
#   make -C port diag-run DIAG=verif/diag/assembly/TLU/direct/tlu_tick_read_1.s
MEM ?= port/build/diag/tlu_tick_read_1.mem

$(BUILD)/tb_diag.vvp: filelist $(ROOT)/port/tb/tb_diag.v
	cd $(ROOT) && $(IVERILOG) -g2005 -s tb_diag \
		-f $(BUILD)/core1_rtl.f \
		design/sys/iop/rtl/iop_fpga.v \
		port/tb/tb_diag.v \
		-o $@

diag: $(BUILD)/tb_diag.vvp
	cd $(ROOT) && $(VVP) $(BUILD)/tb_diag.vvp +memfile=$(MEM) \
		> $(BUILD)/diag_sim.log 2>&1 || \
		{ cat $(BUILD)/diag_sim.log; exit 1; }
	@cat $(BUILD)/diag_sim.log
	@grep -q "DIAG PASS" $(BUILD)/diag_sim.log || \
		{ echo "DIAG FAIL - see $(BUILD)/diag_sim.log"; exit 1; }
	@echo "DIAG PASS"

# Build a diag .mem and run it in one step.
diag-run: $(BUILD)/tb_diag.vvp
	$(PYTHON) $(ROOT)/port/scripts/build_diag.py $(DIAG)
	$(MAKE) -C $(ROOT)/port diag \
		MEM=$$($(PYTHON) $(ROOT)/port/scripts/build_diag.py \
			--mem-path-only $(DIAG))

# ---------------------------------------------------------------
# Playback testbench lane (PCX/CPX stimulus replay)
# ---------------------------------------------------------------
# Replays pre-recorded PCX/CPX stimulus vectors (recorded from the
# original thread1_mini gatesim regression) against the sparc core under
# Icarus.  The archive lives in port/stim, not verif/gatesim.
#   make -C port playback STIM=stim/nop.stimuli
STIM ?= stim/nop.stimuli
STIM_NAME := $(basename $(notdir $(STIM)))
PLAYBACK_STIM_DIR := $(BUILD)/playback/stim
STIM_PATH := $(PLAYBACK_STIM_DIR)/$(notdir $(STIM))

$(PLAYBACK_STIM_DIR)/.extracted: $(ROOT)/port/stim/thread1_mini_stim.tar.gz
	@mkdir -p $(PLAYBACK_STIM_DIR)
	tar -xzf $< -C $(PLAYBACK_STIM_DIR) --strip-components=1
	@touch $@

$(BUILD)/playback.vvp: filelist $(ROOT)/port/tb/tb_playback.v
	cd $(ROOT) && $(IVERILOG) -g2005 -s tb_playback \
		-f $(BUILD)/core1_rtl.f \
		port/tb/playback_driver_oss.v \
		port/tb/tb_playback.v \
		-o $@

playback: $(BUILD)/playback.vvp $(PLAYBACK_STIM_DIR)/.extracted
	cd $(ROOT) && $(VVP) $(BUILD)/playback.vvp +stim_file=$(STIM_PATH) \
		> $(BUILD)/playback_$(STIM_NAME).log 2>&1 || \
		{ cat $(BUILD)/playback_$(STIM_NAME).log; exit 1; }
	@grep -q "Playback PASSED" $(BUILD)/playback_$(STIM_NAME).log || \
		{ echo "PLAYBACK FAIL ($(STIM_NAME)) - see $(BUILD)/playback_$(STIM_NAME).log"; exit 1; }
	@echo "PLAYBACK PASS ($(STIM_NAME))"

playback-nop: ; @$(MAKE) playback STIM=stim/nop.stimuli
playback-simple_br: ; @$(MAKE) playback STIM=stim/simple_br.stimuli

playback-smoke:
	@set -e; for s in nop simple_br; do \
		$(MAKE) playback STIM=stim/$$s.stimuli || \
		{ echo "PLAYBACK SMOKE FAIL (stim/$$s.stimuli)"; exit 1; }; \
	done
	@echo "PLAYBACK SMOKE PASS (nop, simple_br)"

# ---------------------------------------------------------------
# Stage 3: FPGA flow (nextpnr-himbaechel / Gowin GW5AST-138)
# ---------------------------------------------------------------
fpga-flist:
	@mkdir -p $(FPGA_BUILD)
	$(PYTHON) $(ROOT)/port/scripts/gen_fpga_ys.py \
		--root $(ROOT) \
		--top t1_fpga_top \
		--synth gowin \
		--json $(FPGA_BUILD)/t1_fpga.json \
		--extra design/sys/iop/rtl/iop_fpga.v \
		--extra port/fpga/t1_fpga_top.v \
		-o $(FPGA_BUILD)/t1_fpga.ys

fpga-sim: filelist
	cd $(ROOT) && $(IVERILOG) -g2005 -s tb_fpga_top \
		-f $(BUILD)/core1_rtl.f \
		design/sys/iop/rtl/iop_fpga.v \
		port/fpga/t1_fpga_top.v \
		port/tb/tb_fpga_top.v \
		-o $(BUILD)/fpga_smoke.vvp
	cd $(ROOT) && $(VVP) $(BUILD)/fpga_smoke.vvp > $(BUILD)/fpga_smoke.log 2>&1 || \
		{ cat $(BUILD)/fpga_smoke.log; exit 1; }
	@grep -q "FPGA WRAPPER PASS" $(BUILD)/fpga_smoke.log || \
		{ cat $(BUILD)/fpga_smoke.log; echo "FPGA WRAPPER FAIL"; exit 1; }
	@cat $(BUILD)/fpga_smoke.log
	@echo "FPGA WRAPPER PASS"

fpga-synth: fpga-flist
	cd $(ROOT) && $(FPGA_YOSYS) -q -l $(FPGA_BUILD)/synth.log \
		-s $(FPGA_BUILD)/t1_fpga.ys

fpga-pnr: fpga-synth
	cd $(ROOT) && $(NEXTPNR) \
		--device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) \
		--json $(FPGA_BUILD)/t1_fpga.json \
		--vopt cst=$(FPGA_CST) \
		--write $(FPGA_BUILD)/t1_fpga.pnr.json \
		--log $(FPGA_BUILD)/pnr.log \
		--threads $(JOBS) $(FPGA_PNR_FLAGS) \
		--report $(FPGA_BUILD)/t1_fpga.report.json

fpga-bitstream: fpga-pnr
	$(GOWIN_PACK) -d $(FPGA_FAMILY) \
		-o $(FPGA_BUILD)/t1_fpga.fs $(FPGA_BUILD)/t1_fpga.pnr.json
	@echo "BITSTREAM $(FPGA_BUILD)/t1_fpga.fs"

fpga: fpga-bitstream

# Fast toolchain check: one T1 adder, not the full core.
fpga-smoke:
	@mkdir -p $(FPGA_BUILD)
	cd $(ROOT) && $(FPGA_YOSYS) -q \
		-p 'read_verilog design/sys/iop/sparc/exu/rtl/sparc_exu_aluadder64.v port/fpga/t1_fpga_smoke.v' \
		-p 'synth_gowin -family gw5a -top t1_fpga_smoke -json $(FPGA_BUILD)/t1_fpga_smoke.json'
	cd $(ROOT) && $(NEXTPNR) \
		--device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) \
		--json $(FPGA_BUILD)/t1_fpga_smoke.json \
		--vopt cst=$(FPGA_CST) \
		--write $(FPGA_BUILD)/t1_fpga_smoke.pnr.json \
		--log $(FPGA_BUILD)/pnr_smoke.log \
		--freq 50 --threads $(JOBS) --timing-allow-fail
	$(GOWIN_PACK) -d $(FPGA_FAMILY) \
		-o $(FPGA_BUILD)/t1_fpga_smoke.fs $(FPGA_BUILD)/t1_fpga_smoke.pnr.json
	@echo "BITSTREAM $(FPGA_BUILD)/t1_fpga_smoke.fs"

# ---------------------------------------------------------------
# Stage 3: ASIC flow (LibreLane through nix)
# ---------------------------------------------------------------
asic-smoke:
	cd $(ASIC_DIR) && ./run.sh --run-tag smoke --overwrite \
		--hide-progress-bar --condensed config_smoke.yaml

asic-config:
	@mkdir -p $(BUILD)/asic
	$(PYTHON) $(ROOT)/port/scripts/gen_librelane_config.py \
		--root $(ROOT) \
		--top iop_fpga \
		--clock-port gclk \
		--clock-period 10 \
		--extra design/sys/iop/rtl/iop_fpga.v \
		-o $(BUILD)/asic/config_full.yaml

asic-synth: asic-config
	cd $(ASIC_DIR) && ./run.sh --run-tag full-synth --overwrite \
		--hide-progress-bar --condensed \
		--to Yosys.Synthesis $(BUILD)/asic/config_full.yaml

# ---------------------------------------------------------------
# Phase-1 full-chip testbench (cmp_top / OpenSPARCT1 + cmp_dram env)
# ---------------------------------------------------------------
# Proves the whole chip (8 sparc cores + 4 sctag L2 + scbuf/scdata +
# 4 dram controllers + ccx + jbi + ctu + efc + pads) compiles,
# elaborates and resets under Icarus Verilog.  No SJM/PLI emulation;
# the only VPI shim is the silent $dispmon stub (see port/pli/).
#
#   make -C port cmp-build
#   make -C port cmp-run
#
# NOTE: requires the gen'd filelist (make filelist) and
# port/build/dispmon_vpi.vpi (built by cmp-build).
CMPTB_SRC  := port/env/cmp_top_port.v
CMP_DRAM_F := port/env/cmp_dram.f
# DIMM model select: default = functional dimm_mem.v (image preloadable
# via $init_jbus_model); INERT_DIMM=1 falls back to the old dimm_stub.
DIMM_DEFS := $(if $(filter 1,$(INERT_DIMM)),-DINERT_DIMM,)
# iobdg select: IOBDG=1 compiles the real I/O bridge (`-DRTL_IOBDG`), which
# gives the real PCX->i2c->jbi->JBus boot-fetch path and the genuine iobdg
# firstthr_int POR thread-reset packet (replaces the env's CPX injection).
IOBDG_DEFS := $(if $(filter 1,$(IOBDG)),-DRTL_IOBDG,)

$(BUILD)/dispmon_vpi.vpi: $(ROOT)/port/pli/dispmon_vpi.c
	@mkdir -p $(BUILD)
	gcc -shared -fPIC -o $@ $< -I/usr/include/iverilog

$(BUILD)/cmp_top.vvp: filelist $(ROOT)/$(CMPTB_SRC) $(ROOT)/$(CMP_DRAM_F) \
		$(BUILD)/dispmon_vpi.vpi \
		$(wildcard $(ROOT)/port/env/dram/*.v)
	cd $(ROOT) && $(IVERILOG) -g2005 -s cmp_top \
		-f $(BUILD)/core1_rtl.f \
		$(CMPTB_SRC) -f $(CMP_DRAM_F) \
		-DIVPORT_NO_MON $(DIMM_DEFS) \
		-o $(BUILD)/cmp_top.vvp \
		-I. -Iport/tb -Iport/env -Iport/env/dram -Iverif/env/cmp

cmp-build: $(BUILD)/cmp_top.vvp

cmp-run: $(BUILD)/cmp_top.vvp
	cd $(ROOT) && timeout 300 $(VVP) -n \
		-M $(BUILD) -m dispmon_vpi $(BUILD)/cmp_top.vvp \
		> $(BUILD)/cmp_top_smoke.log 2>&1 || \
		{ cat $(BUILD)/cmp_top_smoke.log; exit 1; }
	@cat $(BUILD)/cmp_top_smoke.log
	@grep -q "PHASE1 SMOKE END" $(BUILD)/cmp_top_smoke.log || \
		{ echo "CMP PHASE-1 FAIL - see $(BUILD)/cmp_top_smoke.log"; exit 1; }
	@echo "CMP PHASE-1 PASS (compile + elaborate + reset)"

# ---------------------------------------------------------------
# Unified full-chip integration bench (cmp_top_env):
# OpenSPARCT1 iop + cmp_dram DDR env + jp_sjm JBus slave agents
# (j_sjm_4/j_sjm_5) + $sjm_* VPI (sjm.vpi, embedded at compile time)
# + $dispmon (runtime) + $init_jbus_model (runtime).
#
#   make -C port cmp-env-build
#   make -C port cmp-env-run
#
# SJM command files: the SJM C model (verif .../c/main.cc front_init)
# opens "sjm_<id>.cmd" in the *current directory* (or
# "<diag>_<id>.cmd" via +safari=<diag>); there is no per-id plusarg.
# cmp-env-run therefore cds into $(BUILD)/sjm_run with the default
# iss fixtures copied there.  Override per-diag by copying your own
# sjm_4.cmd / sjm_5.cmd into $(BUILD)/sjm_run before running.
# ---------------------------------------------------------------
ENV_SRC    := port/env/cmp_top_env.v
# Port copy of verif/env/iss/pli/sjm/rtl/sjm.v with task-style $sjm_* calls
# (Icarus registers each name as a system task only; the legacy function-style
# "temp = $sjm_..." call sites do not elaborate).
SJM_RTL    := port/env/sjm_front.v
SJM_FIXDIR := verif/env/iss/pli/sjm/c
SJM_RUNDIR := $(BUILD)/sjm_run

# sjm.vpi (compile-time embed: passed to iverilog as -m; do NOT also
# pass -msjm to vvp - that double-registers the tasks).
$(ROOT)/port/pli/sjm/sjm.vpi:
	$(MAKE) -C $(ROOT)/port/pli/sjm

# init_jbus_model.vpi (runtime module; iverilog-vpi names the module
# after the source file: load with -m init_jbus_model_vpi)
IVERILOG_VPI ?= iverilog-vpi
$(ROOT)/port/pli/init_jbus_model_vpi.vpi: $(ROOT)/port/pli/init_jbus_model_vpi.c
	cd $(ROOT)/port/pli && $(IVERILOG_VPI) init_jbus_model_vpi.c

# dispmon.vpi (runtime module; build only if missing - keep proven artifact)
$(ROOT)/port/pli/dispmon.vpi:
	@test -f $@ || (cd $(ROOT)/port/pli && $(IVERILOG_VPI) dispmon_vpi.c)

$(BUILD)/cmp_top_env.vvp: filelist $(ROOT)/$(ENV_SRC) $(ROOT)/$(CMP_DRAM_F) \
		$(ROOT)/$(SJM_RTL) $(ROOT)/port/pli/sjm/sjm.vpi
	cd $(ROOT) && $(IVERILOG) -g2005 -s cmp_top \
		-f $(BUILD)/core1_rtl.f \
		$(ENV_SRC) -f $(CMP_DRAM_F) $(SJM_RTL) \
		port/env/mem_backdoor.v \
		port/env/monitor_min.v \
		-DIVPORT_NO_MON $(DIMM_DEFS) $(IOBDG_DEFS) \
		-L $(ROOT)/port/pli/sjm -m sjm \
		-o $(BUILD)/cmp_top_env.vvp \
		-I. -Iport/tb -Iport/env -Iport/env/dram -Iverif/env/cmp

cmp-env-build: $(BUILD)/cmp_top_env.vvp \
		$(ROOT)/port/pli/init_jbus_model_vpi.vpi \
		$(ROOT)/port/pli/dispmon.vpi

# Unit check of the functional DIMM (dimm_mem.v): DDR-command-path
# write + read-back against the local array.
dimm-unit:
	cd $(ROOT) && $(IVERILOG) -g2005 -s dimm_unit_tb \
		port/env/dram/dimm_mem.v port/env/dram/dimm_unit_tb.v \
		-o $(BUILD)/dimm_unit.vvp
	cd $(ROOT) && $(VVP) $(BUILD)/dimm_unit.vvp | tee $(BUILD)/dimm_unit.log
	@grep -q "DIMM UNIT PASS" $(BUILD)/dimm_unit.log || \
		{ echo "DIMM UNIT FAIL"; exit 1; }

cmp-env-run: $(BUILD)/cmp_top_env.vvp $(ROOT)/port/pli/init_jbus_model_vpi.vpi
	@mkdir -p $(SJM_RUNDIR)
	@test -f $(SJM_RUNDIR)/sjm_4.cmd || cp $(ROOT)/$(SJM_FIXDIR)/sjm_4.cmd $(SJM_RUNDIR)/
	@test -f $(SJM_RUNDIR)/sjm_5.cmd || cp $(ROOT)/$(SJM_FIXDIR)/sjm_5.cmd $(SJM_RUNDIR)/
	@test -f $(SJM_RUNDIR)/mem.image || cp $(ROOT)/port/env/mem.image $(SJM_RUNDIR)/
	@# also honour explicit +mem.image / +sjm_cmd overrides below
	@# +sjm_trigger_force forces the SJM start (see cmp_top_env.v: the CTU
	@# chain that deasserts jbus_grst_l is not exercised yet in bring-up).
	cd $(SJM_RUNDIR) && timeout 120 $(VVP) -n \
		-M $(ROOT)/port/pli -m dispmon \
		-M $(ROOT)/port/pli -m init_jbus_model_vpi \
		$(BUILD)/cmp_top_env.vvp $(SJM_PLUSARGS) +sjm_trigger_force=1200000 \
		> $(BUILD)/cmp_top_env_smoke.log 2>&1 || \
		{ cat $(BUILD)/cmp_top_env_smoke.log; exit 1; }
	@cat $(BUILD)/cmp_top_env_smoke.log
	@grep -q "CMP-ENV SMOKE END" $(BUILD)/cmp_top_env_smoke.log || \
		{ echo "CMP-ENV FAIL - see $(BUILD)/cmp_top_env_smoke.log"; exit 1; }
	@echo "CMP-ENV PASS (full chip + DDR + SJM 4/5 + POR)"


clean:
	rm -rf $(BUILD)
