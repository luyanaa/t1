# Playback lane

`port/stim/thread1_mini_stim.tar.gz` contains PCX/CPX vectors recorded from
the original Sun `thread1_mini` gate-level regression (42 vector files,
`stim/*.stimuli` plus one gzipped stimulus).  The open port replays them
against the `sparc` RTL with `port/tb/playback_driver_oss.v` and
`port/tb/tb_playback.v`;
the driver is the Icarus-compatible copy of
`verif/env/cmp/playback_driver.v`.

## Run

```sh
make -C port playback-nop
make -C port playback-simple_br
make -C port playback STIM=stim/exu_alu.stimuli
```

The archive is extracted to `port/build/playback/stim/`.

## Status

This lane is a replay harness, not a passing regression.  The vectors were
recorded from a gate netlist with different array initialization, so the
current RTL reports mismatches (for example, 12,898 on `nop`).  It is
useful for bringing up a gate-level netlist once one exists, but it is not
part of `make -C port regress`.

## Removed legacy pieces

The original `verif/gatesim/` README described a VCS flow:

- `build_gates <flist>` (VCS `simv`)
- `run_gates <stim>` (VCS `simv`)
- `flist.xilinx_unisims` (Xilinx unisim libraries)

Those were removed with the VCS/Xilinx flow.  The stimulus archive and the
playback driver were kept because they do not depend on either tool.
