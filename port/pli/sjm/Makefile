# OpenSPARC T1 SJM -> Icarus Verilog VPI port (port/pli/sjm/Makefile)
#
# Builds sjm.vpi, a loadable VPI module for Icarus Verilog containing:
#
# Build:   make
# Compile: iverilog -msjm -o tb.vvp tb.v     (-m makes the tasks known to ivl)
# Run:     vvp -M. -msjm tb.vvp

# Read-only reference tree (never modified).
VERIF_SJM ?= /shared/t1/verif/env/iss/pli/sjm/c
VERIF_COMMON ?= /shared/t1/verif/env/iss/pli/common/c

CXX      ?= g++
CXXFLAGS ?= -g -O1 -fPIC -w
CXXFLAGS += -fpermissive            # 2006-era K&Cisms in the old code
CXXFLAGS += -DFIFO_METHOD -DLINUX   # same defines the VCS build used

CXXFLAGS += -include cstdlib -include cstring -include cctype \
            -include $(CURDIR)/include/prelude.h
# NULL/strlen/isdigit/null/TRUE/FALSE are used in old headers without includes.

# Engine sources call dprintf(unit, tag, flags, ...) — rename it out of the way
# of the POSIX dprintf(int, fd, ...) prototype.
ENGINE_CXXFLAGS = $(CXXFLAGS) -Ddprintf=sjm_dprintf

# shim headers FIRST, so "veriuser.h"/"acc_user.h" resolve to our fakes.
CXXFLAGS += -I./include -I/usr/include/iverilog -I$(VERIF_SJM) -I$(VERIF_COMMON)

# Engine sources, identical to the VCS Makefile CSRCS (main.cc excluded;
# it is included by vpi_main.cc).
ENGINE_SRCS = $(VERIF_SJM)/SJM.cc $(VERIF_SJM)/Arbiter.cc \
              $(VERIF_SJM)/InterruptControl.cc $(VERIF_SJM)/SnoopControl.cc \
              $(VERIF_SJM)/ByteString.cc $(VERIF_SJM)/Parser.cc \
              $(VERIF_SJM)/Command.cc $(VERIF_SJM)/Cache.cc \
              $(VERIF_SJM)/Transaction.cc $(VERIF_SJM)/ReadOutBuffer.cc \
              $(VERIF_SJM)/MemoryControl.cc $(VERIF_SJM)/RegisterFile.cc
SYNC_SRCS = $(VERIF_COMMON)/sync_int.cc \
            $(VERIF_COMMON)/StringTokenizer.cc \
            $(VERIF_COMMON)/ListTree.cc \
            $(VERIF_COMMON)/DoubleLinkedList.cc \
            $(VERIF_COMMON)/CircularLinkedList.cc

SHIM_SRCS = tfacc_vpi.cc vpi_main.cc

OBJS = $(patsubst %.cc,build/%.o,$(notdir $(ENGINE_SRCS) $(SYNC_SRCS) $(SHIM_SRCS)))

VPILDFLAGS := $(shell iverilog-vpi 2>/dev/null | grep -o -- '-shared[^ ]* -o sjm.vpl' || true)

all: sjm.vpi

build:
	mkdir -p build

build/%.o: $(VERIF_SJM)/%.cc | build
	$(CXX) $(ENGINE_CXXFLAGS) -c $< -o $@

# Local port copies (verbatim verif sources with documented fixes).
build/main.o build/Parser.o: build/%.o: %.cc | build
	$(CXX) $(ENGINE_CXXFLAGS) -c $< -o $@

build/%.o: $(VERIF_COMMON)/%.cc | build
	$(CXX) $(ENGINE_CXXFLAGS) -c $< -o $@

build/tfacc_vpi.o: tfacc_vpi.cc | build
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/vpi_main.o: vpi_main.cc | build
	$(CXX) $(CXXFLAGS) -I$(VERIF_SJM) -c $< -o $@

# Link as a vvp loadable module (.vpl = plain shared object). iverilog-vpi is
# only used to query the correct linker flags for this install.
# iverilog-vpi outputs sjm.vpi directly (vvp's ".vpl" is just a convention).
sjm.vpi: $(OBJS)
	iverilog-vpi --name=sjm $(OBJS)

tb.vvp: test/tb.v sjm.vpi
	iverilog -L. -msjm -o tb.vvp test/tb.v

test: all tb.vvp test/tb2.vvp
	vvp tb.vvp          # module is already embedded by iverilog -msjm; do
	                  # not also pass -m to vvp (would register twice)
	cd test && vvp -M.. -msjm tb2.vvp 2>&1 | grep -v DEBUG

test/tb2.vvp: test/tb2.v sjm.vpi
	iverilog -L. -msjm -o test/tb2.vvp test/tb2.v

clean:
	rm -rf build sjm.vpi tb.vvp test/tb2.vvp

.PHONY: all test clean
