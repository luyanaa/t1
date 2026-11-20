#!/bin/bash
# run_diag.sh <diag.s> [timeout_s] -> prints verdict
d=$1; to=${2:-300}
name=$(basename "$d" .s)
mem=port/build/diag/$name/$name.mem
make -C port diag-build DIAG="$d" >/dev/null 2>&1 || { echo "$name: BUILD-FAIL"; exit 1; }
timeout "$to" vvp -n port/build/tb_diag.vvp +memfile="$mem" +max_cycle=200000000 > /tmp/opencode/run_$name.log 2>&1
v=$(grep -oE 'DIAG (PASS|FAIL)' /tmp/opencode/run_$name.log | head -1)
echo "$name: ${v:-TIMEOUT(no verdict)}"
