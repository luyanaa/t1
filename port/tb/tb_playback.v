`timescale 1ns/1ns

// Thin top-level wrapper around verif/env/cmp/playback_driver.v.
//
// playback_driver (module cmp_top) is self-contained: it instantiates the
// sparc core, generates the 836 ns period gclk, reads the +stim_file=<path>
// .stimuli vector file and self-checks PCX outputs.  This wrapper adds only
// a wall-clock timeout guard so an empty/invalid stim file (which makes
// $fscanf return EOF at t=0 before the driver prints a verdict) or a hung
// core cannot run forever.

module tb_playback;

    playback_driver iop();

    // Timeout guard: ~10 ms of sim time (far beyond any mini_stim vector
    // set).  Fires only if the driver neither PASSED nor FAILED by then.
    initial begin
        #10_000_000;
        $display("Playback TIMEOUT: no verdict after %0t sim time", $time);
        $finish;
    end

endmodule
