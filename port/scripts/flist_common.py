#!/usr/bin/env python3
"""Shared helpers for Sun `sims` file lists.

The three port generators (gen_filelist.py, gen_fpga_ys.py,
gen_librelane_config.py) parse the same Sun .flist syntax.  Keep the
parser, the FPGA/ASIC default defines, and the default include dirs here
so the three entry points cannot drift.
"""

import os
import re

# Defines used by both the Gowin and LibreLane full-core flows.
DEFAULT_DEFINES = [
    "FPGA_SYN", "FPGA_SYN_NO_SPU", "FPGA_SYN_16TLB",
    "MODEL_CMP", "RTL_FLOP_RPTRS", "RTL_CMP", "RTL_MEM",
    "RTL_SPARC0", "RTL_FPU", "RTL",
]

DEFAULT_INCDIRS = [
    "design/sys/iop/include",
    "design/sys/iop/ctu/rtl",
    "design/sys/iop/ctu/include",
    "design/sys/iop/jbi/include",
    "design/sys/iop/jbi/jbi_mout/rtl",
    "design/sys/iop/sctag/rtl",
    "design/sys/iop/srams/rtl",
]


def strip_comment(line):
    return line.split("//", 1)[0].strip()


def expand_vars(text, dv_root):
    def repl(match):
        name = match.group(1)
        if name == "DV_ROOT":
            return dv_root
        return os.environ.get(name, match.group(0))

    return re.sub(r"\$(\w+)", repl, text)


def resolve(value, base):
    if os.path.isabs(value):
        return os.path.normpath(value)
    return os.path.normpath(os.path.join(base, value))


def read_flist_entries(path, dv_root):
    """Parse a Sun .flist into (kind, value) entries.

    kind is one of incdir, define, lib, libdir, file.
    """
    entries = []
    base = os.path.dirname(os.path.abspath(path))
    with open(path, encoding="latin-1") as fh:
        for raw in fh:
            line = strip_comment(raw)
            if not line:
                continue
            line = expand_vars(line, dv_root)
            if line.startswith("+libext+") or line.startswith("+librescan"):
                continue
            if line.startswith("+incdir+"):
                entries.append(("incdir", resolve(
                    line[len("+incdir+"):].strip(), base)))
            elif line.startswith("+define+"):
                entries.append(("define", line[len("+define+"):].strip()))
            elif line.startswith("-v "):
                entries.append(("lib", resolve(line[3:].strip(), base)))
            elif line.startswith("-y "):
                entries.append(("libdir", resolve(line[3:].strip(), base)))
            else:
                entries.append(("file", resolve(line, base)))
    return entries


def read_flist_files(path):
    """Return the source paths from a .flist, skipping headers.

    Used by the synthesizer config generators, which only need Verilog
    sources (no incdir/define directives).
    """
    files = []
    with open(path, encoding="latin-1") as fh:
        for raw in fh:
            line = raw.split("//", 1)[0].strip()
            if not line:
                continue
            if line.endswith(".h") or line.endswith(".vh"):
                continue
            files.append(line)
    return files
