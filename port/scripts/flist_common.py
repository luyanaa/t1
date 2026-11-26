#!/usr/bin/env python3
"""Shared helpers for Sun `sims` file lists.

The three port generators (gen_filelist.py, gen_fpga_ys.py,
gen_librelane_config.py) parse the same Sun .flist syntax.  Keep the
parser, the FPGA/ASIC default defines, and the default include dirs here
so the three entry points cannot drift.
"""

import os
import re
import sys

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


def read_flist_files(path, root=None):
    """Return the source paths from a .flist, skipping headers.

    Used by the synthesizer config generators, which only need Verilog
    sources (no incdir/define directives).

    The entries in a Sun .flist are written relative to the tree root
    (``design/...``, ``lib/...``), not to the .flist file itself.  Pass
    ``root`` to resolve them; otherwise the caller must join them with the
    root itself.
    """
    files = []
    with open(path, encoding="latin-1") as fh:
        for raw in fh:
            line = raw.split("//", 1)[0].strip()
            if not line:
                continue
            if line.endswith(".h") or line.endswith(".vh"):
                continue
            files.append(line if root is None else os.path.join(root, line))
    return files


def check_sources(files, what):
    """Fail loudly when a generated source list points at a missing file.

    ``read_verilog`` in Yosys and the LibreLane file list both accept a
    non-existent path without an error at parse time; the failure only
    shows up much later as a missing module, which looks like an RTL
    problem.  Catch it here, where the path was written.
    """
    missing = [f for f in files if not os.path.isfile(f)]
    if missing:
        for f in missing[:20]:
            print("missing %s source: %s" % (what, f), file=sys.stderr)
        raise SystemExit(
            "%d of %d %s source files do not exist" % (
                len(missing), len(files), what))
