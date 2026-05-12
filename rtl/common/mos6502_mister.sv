// SPDX-License-Identifier: MIT
//
// mos6502_mister — wrapper around mos6502_core with a MiSTer-friendly
// interface.
//
// The MiSTer NES / Atari / Commodore cores typically expect a 6502 module
// that provides:
//   - phi1 / phi2 derived output clocks
//   - synchronous tristate-on-write bus emulation through bidi data
//   - explicit IRQ / NMI inputs (level-sensitive style is fine for the
//     wrapper; the core handles the NMI edge internally)
//
// This wrapper exposes those signals on top of the synchronous single-edge
// core. `clk` is the external high-speed clock and `cen` ("clock enable") is
// asserted for one cycle per bus cycle — the same cadence MiSTer cores use
// for the 6502.
//
// Notes:
// - This is a thin shim; the core itself is unchanged. No FSM modifications.
// - data_in / data_out are exposed separately; the integrator multiplexes
//   them as needed (some platforms use bidi nets, some don't).

`default_nettype none

module mos6502_mister (
    input  logic        clk,
    input  logic        cen,           // bus-cycle enable
    input  logic        reset_n,

    input  logic        irq_n,
    input  logic        nmi_n,
    input  logic        rdy,           // active-high (MiSTer convention)
    input  logic        so_n,

    output logic [15:0] address,
    input  logic [7:0]  data_in,
    output logic [7:0]  data_out,
    output logic        rw,
    output logic        sync,

    // Phi clock outputs for legacy peripherals. Generated from cen.
    output logic        phi1_out,
    output logic        phi2_out
);

    // Gate the core's clock with the enable so one cen pulse advances by
    // exactly one bus cycle. clk_gated must be a clean (glitch-free) gate;
    // in a real FPGA target this should be replaced with the vendor's
    // clock-enable primitive or a synchronous `if (cen)` discipline.
    logic core_clk;
    assign core_clk = clk;

    // Phi outputs: phi1 high for the first half of a cen-cycle, phi2 high
    // for the second half. Approximate with a toggle gated by cen.
    logic phi_state_q;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) phi_state_q <= 1'b0;
        else if (cen) phi_state_q <= !phi_state_q;
    end
    assign phi1_out = !phi_state_q;
    assign phi2_out =  phi_state_q;

    // Pass `cen` through as the core's `ready` so the core only advances
    // when cen is asserted (any cycle where cen=0 the core stalls,
    // emulating bus pause).
    mos6502_core u_core (
        .clk      (core_clk),
        .reset_n  (reset_n),
        .irq_n    (irq_n),
        .nmi_n    (nmi_n),
        .ready    (cen && rdy),
        .so_n     (so_n),
        .address  (address),
        .data_in  (data_in),
        .data_out (data_out),
        .rw       (rw),
        .sync     (sync)
    );

endmodule

`default_nettype wire
