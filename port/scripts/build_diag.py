#!/usr/bin/env python3
"""Build a legacy "direct"-style SPARC T1 diag into a $readmemh memory image.

Usage:
    build_diag.py <diag.s> [-o out.mem]

Pipeline
--------
1.  cpp -P the diag with:
      -I port/scripts/t1boot_shim   (shadows `boot.s` with a minimal GNU-as
                                     boot harness, see t1boot_min.s)
      -I verif/diag/assembly/include (all other legacy includes)
      plus the diag's own `#define`d flags, which are extracted automatically
      from the diag source (e.g. CIOP, THREAD_MASK, NO_TRAPCHECK, PCONTEXT..).
2.  Assemble with GNU as:  sparc64-linux-gnu-as -Av9b
    (verified to accept all T1/sun4v constructs used by the diags:
     wrpr/rdpr %pstate/%tstate/%tl, rdhpr/wrhpr %htba/%htstate, done, retry,
     ta %icc,N, GNU's `setx` 64-bit pseudo-instruction, %rN register names,
     rd/wr %asr26 halt register.  `halt` is rejected -> never used by diags.)
3.  Link with port/scripts/t1boot.ld at the fixed map documented in
    t1boot_min.s:
      PA 0xfff0000000  trap table + boot body (RED page; reset trap tt=0x02
                       lands at PA 0xfff0000040, exactly what tb_core_smoke.v
                       serves at 0xfffff0000040 -> 0xfff0000040)
      PA 0x10000000    diag .text   (MMU off: VA == PA)
      PA 0x10001000    diag .data/.bss
      PA 0x10002000    thread_status_mem (one-hot PASS/FAIL word the TB watches)
    NOTE: this differs from the legacy midas map, which links main text at
    MAIN_BASE_TEXT_VA 0x20000000 / RA 0x130000000 and requires the full
    hboot TLB init (hboot_tlb_init.s) because midas serves images by PA
    (MI_ arrays in mbfw_diag_memimage.c: boot 0xfff0000000-ish, kernel
    0x40000/0x80000, main 0x130000000).  Porting that map requires the
    full TLB-init boot; see "blockers" in the report.
4.  sparc64-linux-gnu-ld -T t1boot.ld, then diag2hex.py converts the ELF
    to port/build/diag/<name>.mem  (sparse $readmemh, 64-bit BE words,
    @idx = pa/8 — same convention as port/stim/l2_buf.mem).

Disassembly sanity check: run with --objdump to see sparc64-linux-gnu-objdump.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

ASSEMBLER = "sparc64-linux-gnu-as"
AS_ARCH = "-Av9b"          # empirically verified flag for T1 sun4v insns
CPP = "cpp"

# Directives in the midas/assembler dialect that GNU as cannot handle.
MIDAS_RE = re.compile(r"^\s*(SECTION\b|attr_text\b|attr_data\b|attr_bss\b)")

# Diag-source `#define`s that are forwarded as cpp -D flags (others are left
# in the source, where cpp expands them normally).  We pass ALL of them as
# -D so that include chains condition on the same set the legacy flow used.
DEFINE_RE = re.compile(r"^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)(\s|\b|$)")


def collect_defines(src: str):
    """Diag's own #define names (first token), excluding macro-with-args."""
    names = set()
    with open(src) as f:
        for line in f:
            m = DEFINE_RE.match(line)
            if m:
                name = m.group(1)
                # macro with parameters:  #define  FOO(a, b)
                after = line[m.start(2) if m.group(2) else len(line):]
                if re.match(r"\s*\(", line[m.end(1):]):
                    continue
                names.add(name)
    return sorted(names)


def preprocess(diag: str, extra_defines):
    inc_legacy = os.path.join(ROOT, "verif/diag/assembly/include")
    inc_shim = os.path.join(HERE, "t1boot_shim")
    cmd = [CPP, "-P",
           "-I", inc_shim,          # FIRST: shadows boot.s
           "-I", inc_legacy]
    for d in extra_defines:
        cmd += ["-D", d]
    cmd.append(diag)
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        raise SystemExit("cpp failed for %s" % diag)
    return res.stdout


def expand_th_fork(pp_text: str, mask: int = None) -> str:
    """Expand the midas/m4 `th_fork(label)` / `th_fork_jmp_p(label)` macros.

    Legacy expansion (macros.m4 start_fork_expand):
        rdth_id                      ->  ta T_RD_THID   (thread id -> %o1)
        foreachbit i in THREAD_MASK:
            cmp  %o1, i
            be   label_i
            nop
        ta   T_BAD_TRAP

    THREAD_MASK comes from the diag's #define THREAD_MASK (default 1,
    i.e. thread 0 only).  We emit the compare-branch for every bit set in
    the mask; single-thread diags get just `i=0`.  `th_fork_jmp_p` jumps
    via %g3 instead of branching; used by mt_template diags (out of
    scope, but handled the same way for completeness).

    `mask` is normally passed in from the diag *source*: cpp has already
    deleted the `#define THREAD_MASK` line by the time we see pp_text, so
    the fallback regex below only catches a mask that survived cpp.
    """
    if mask is None:
        # capture diag's THREAD_MASK if defined (hex/dec literal)
        m = re.search(r"^\s*#\s*define\s+THREAD_MASK\s+([0-9a-fA-Fx]+)",
                      pp_text, re.M)
        mask = int(m.group(1), 0) if m else 0x1
    if mask == 0:
        mask = 0x1

    def repl(match):
        kind, label = match.group(1), match.group(2)
        lines = ["\t! th_fork({0}) expanded (THREAD_MASK={1:#x})".format(label, mask),
                 "\tta\t0x2e\t\t! T_RD_THID"]
        for i in range(32):
            if mask & (1 << i):
                if kind == "th_fork_jmp_p":
                    lines += ["\tcmp\t%o1, {0}".format(i),
                              "\tsetx\t{0}_{1}, %g2, %g3".format(label, i),
                              "\tbe,a\t.+8",
                              "\tjmp\t%g3",
                              "\tnop"]
                else:
                    lines += ["\tcmp\t%o1, {0}".format(i),
                              "\tbe\t{0}_{1}".format(label, i),
                              "\tnop"]
        lines.append("\tta\t0x01\t\t! T_BAD_TRAP")
        return "\n".join(lines)

    return re.sub(r"^[ \t]*(th_fork|th_fork_jmp_p)\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)",
                  repl, pp_text, flags=re.M)


def check_midas(pp_text: str, diag: str):
    bad = []
    for i, line in enumerate(pp_text.splitlines(), 1):
        if MIDAS_RE.match(line):
            bad.append((i, line.strip()))
    if bad:
        for i, line in bad[:10]:
            sys.stderr.write("midas-only directive at pp-line %d: %s\n" % (i, line))
        raise SystemExit(
            "%s uses midas SECTION/attr_* directives that GNU as cannot "
            "assemble (porting these requires the full hboot TLB-init boot). "
            "Blocked." % diag)


def assemble(pp_text: str, work: str):
    # GNU `as` concatenates its inputs, so any section directive left open
    # at the end of t1boot_min.s would swallow the diag code.  Force the
    # diag into .text explicitly.
    pp_file = os.path.join(work, "diag_pp.s")
    with open(pp_file, "w") as f:
        f.write("\t.section .text\n" + pp_text)
    elf = os.path.join(work, "diag.elf")
    cmd = [ASSEMBLER, AS_ARCH,
           os.path.join(HERE, "t1boot_min.s"), pp_file,
           "-o", os.path.join(work, "diag.o")]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        raise SystemExit("as failed")
    res = subprocess.run(
        ["sparc64-linux-gnu-ld", "-T", os.path.join(HERE, "t1boot.ld"),
         os.path.join(work, "diag.o"), "-o", elf],
        capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        raise SystemExit("ld failed")
    return elf


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("diag")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--objdump", action="store_true",
                    help="print the objdump disassembly of the result")
    ap.add_argument("--mem-path-only", action="store_true",
                    help="only print the .mem output path and exit")
    args = ap.parse_args()

    diag = args.diag
    if not os.path.exists(diag):     # make runs with cwd=port
        alt = os.path.join(ROOT, diag)
        if os.path.exists(alt):
            diag = alt
    name = os.path.splitext(os.path.basename(diag))[0]
    work = os.path.join(ROOT, "port/build/diag", name)
    mem = args.out or os.path.join(work, name + ".mem")
    if args.mem_path_only:
        print(mem)
        return 0
    os.makedirs(work, exist_ok=True)

    defines = collect_defines(diag)
    print("build_diag: per-diag defines:", " ".join(defines) or "(none)")

    # THREAD_MASK is read from the diag source, before cpp deletes the
    # `#define THREAD_MASK` line.
    with open(diag) as f:
        src_text = f.read()
    m = re.search(r"^\s*#\s*define\s+THREAD_MASK\s+([0-9a-fA-Fx]+)",
                  src_text, re.M)
    mask = int(m.group(1), 0) if m else None
    if mask is not None:
        print("build_diag: THREAD_MASK=%#x" % mask)

    pp_text = preprocess(diag, defines)
    pp_text = expand_th_fork(pp_text, mask)
    check_midas(pp_text, diag)
    elf = assemble(pp_text, work)

    subprocess.run([sys.executable, os.path.join(HERE, "diag2hex.py"),
                    elf, mem], check=True)

    if args.objdump:
        subprocess.run(["sparc64-linux-gnu-objdump", "-d", elf])
    else:
        subprocess.run(
            ["sparc64-linux-gnu-objdump", "-d", "-j", ".text", elf],
            stdout=open(os.path.join(work, name + ".lst"), "w"), check=True)
        print("build_diag: disassembly ->", os.path.join(work, name + ".lst"))
    print("build_diag: image ->", mem)
    return 0


if __name__ == "__main__":
    sys.exit(main())
