#!/usr/bin/env python3
"""Generate open-source simulator and synthesis file lists from a Sun
`sims` config.

The config format is the one used by `port/config/core1.config`: a list of
`-flist=`, `-config_rtl=`, and `-env_base=` directives.  The `.flist` files are
kept as the single source of truth; this script only resolves variables and
filters entries for the requested flow.
"""

import argparse
import os
import shlex

from flist_common import (
    expand_vars,
    read_flist_entries,
    resolve,
    strip_comment,
)


def under_roots(path, roots):
    path = os.path.abspath(path)
    return any(path == root or path.startswith(root + os.sep) for root in roots)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=None,
                    help="sims config (default: port/config/core1.config)")
    ap.add_argument("--dv-root", default=None,
                    help="value used for $DV_ROOT (default: repository root)")
    ap.add_argument("--mode", choices=("rtl", "full"), default="rtl",
                    help="rtl: design and lib only; full: include verif")
    ap.add_argument("-o", "--output", required=True,
                    help="output file list")
    ap.add_argument("--config-v", default=None,
                    help="optional generated Verilog define file")
    ap.add_argument("--yosys", default=None,
                    help="optional generated Yosys script")
    ap.add_argument("--top", default="sparc",
                    help="top module for the Yosys hierarchy check")
    args = ap.parse_args()

    if args.dv_root:
        dv_root = os.path.abspath(args.dv_root)
    else:
        dv_root = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))))
    config = args.config or os.path.join(
        dv_root, "port", "config", "core1.config")

    defines = []
    incdirs = []
    entries = []

    with open(config, encoding="latin-1") as fh:
        for raw in fh:
            line = strip_comment(raw)
            if not line:
                continue
            if line.startswith("-flist="):
                flist = expand_vars(line[len("-flist="):].strip(), dv_root)
                entries.extend(read_flist_entries(flist, dv_root))
            elif line.startswith("-config_rtl="):
                defines.append(line[len("-config_rtl="):].strip())
            elif line.startswith("-env_base="):
                incdir = expand_vars(line[len("-env_base="):].strip(), dv_root)
                incdirs.append(incdir)

    allowed = [os.path.join(dv_root, "design"), os.path.join(dv_root, "lib")]
    selected = []
    selected_by_path = {}
    seen_incdirs = set()

    def add(kind, value):
        if kind == "incdir":
            key = (kind, os.path.abspath(value))
            if key in seen_incdirs:
                return
            seen_incdirs.add(key)
            selected.append((kind, value))
            return
        ext = os.path.splitext(value)[1].lower()
        if ext in (".h", ".hpp", ".inc", ".vh"):
            return
        path = os.path.abspath(value)
        prior = selected_by_path.get(path)
        if prior is None:
            selected_by_path[path] = len(selected)
            selected.append((kind, value))
        elif kind == "file" and prior is not None:
            selected[prior] = (kind, value)

    for incdir in incdirs:
        if os.path.isdir(incdir):
            add("incdir", incdir)

    for kind, value in entries:
        if kind == "define":
            if value not in defines:
                defines.append(value)
            continue
        if kind not in ("incdir", "lib", "libdir", "file"):
            continue
        if args.mode == "rtl" and kind != "incdir" and not under_roots(
                value, allowed):
            continue
        if not os.path.exists(value):
            continue
        add(kind, value)

    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output, "w", encoding="utf-8") as out:
        for name in defines:
            out.write("+define+%s\n" % name)
        out.write("+define+NO_VERA\n")
        out.write("+define+FSDB_OFF\n")
        for kind, value in selected:
            if kind == "incdir":
                out.write("+incdir+%s\n" % value)
        for kind, value in selected:
            if kind == "lib":
                out.write("-v %s\n" % value)
            elif kind == "libdir":
                out.write("-y %s\n" % value)
            elif kind == "file":
                out.write("%s\n" % value)

    if args.config_v:
        with open(args.config_v, "w", encoding="utf-8") as out:
            for name in defines:
                out.write("`define %s\n" % name.replace("=", " ", 1))

    if args.yosys:
        yosys_defines = defines + ["NO_VERA", "FSDB_OFF"]
        yosys_incdirs = [value for kind, value in selected if kind == "incdir"]
        yosys_libs = [value for kind, value in selected
                      if kind in ("lib", "libdir")
                      and "/pads/" not in value.replace(os.sep, "/")]
        yosys_files = [value for kind, value in selected
                       if kind == "file"
                       and "/pads/" not in value.replace(os.sep, "/")]
        with open(args.yosys, "w", encoding="utf-8") as out:
            out.write("# Generated by port/scripts/gen_filelist.py\n")
            out.write("# Pad models are omitted: they use drive strengths that\n")
            out.write("# Yosys cannot parse and are outside the core netlist.\n")
            for name in yosys_defines:
                out.write("verilog_defaults -add %s\n" % shlex.quote("-D" + name))
            for incdir in yosys_incdirs:
                out.write("verilog_defaults -add %s\n" % shlex.quote("-I" + incdir))
            for start in range(0, len(yosys_files), 40):
                chunk = yosys_files[start:start + 40]
                out.write("read_verilog %s\n" % " ".join(
                    shlex.quote(value) for value in chunk))
            for start in range(0, len(yosys_libs), 40):
                chunk = yosys_libs[start:start + 40]
                out.write("read_verilog -lib %s\n" % " ".join(
                    shlex.quote(value) for value in chunk))
            out.write("hierarchy -check -top %s\n" % shlex.quote(args.top))

    counts = {}
    for kind, _ in selected:
        counts[kind] = counts.get(kind, 0) + 1
    print("config: %s" % config)
    print("mode:   %s" % args.mode)
    print("output: %s" % args.output)
    print("defines: %d, incdirs: %d, files: %d, libraries: %d" % (
        len(defines), counts.get("incdir", 0), counts.get("file", 0),
        counts.get("lib", 0)))


if __name__ == "__main__":
    main()
