#!/usr/bin/env bash
# Run LibreLane through the pinned nix shell.
#
# The CIEL PDK metadata installed here describes standard-cell libraries
# with CELL_LIBS, while LibreLane expects LIB.  Derive the LIB
# override from the PDK tree so the checked-in configs stay portable.
set -euo pipefail

PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
PDK=${PDK:-sky130A}
SCL=${STD_CELL_LIBRARY:-sky130_fd_sc_hd}
CORNER=${PDK_CORNER:-tt_025C_1v80}

# LibreLane's default sky130 STA grid checks tt, ss and ff PVT corners.
PDK_CORNERS="tt_025C_1v80 ss_100C_1v60 ff_n40C_1v95"

OVERRIDE=$(mktemp "${TMPDIR:-/tmp}/librelane-pdk-XXXXXX.yaml")
trap 'rm -f "$OVERRIDE"' EXIT
{
    echo "LIB:"
    for c in $PDK_CORNERS; do
        lib="$PDK_ROOT/$PDK/libs.ref/$SCL/lib/${SCL}__${c}.lib"
        if [ ! -f "$lib" ]; then
            echo "error: liberty file not found: $lib" >&2
            exit 1
        fi
        echo "  \"*_${c}\":"
        echo "    - $lib"
    done
    echo "DEFAULT_CORNER: \"nom_${CORNER}\""
} > "$OVERRIDE"

nix develop /opt/librelane -c librelane \
    --manual-pdk \
    --pdk-root "$PDK_ROOT" \
    -p "$PDK" \
    "$OVERRIDE" \
    "$@"