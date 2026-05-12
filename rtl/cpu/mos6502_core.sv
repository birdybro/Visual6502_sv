// SPDX-License-Identifier: MIT
//
// mos6502_core — synthesizable SystemVerilog reimplementation of the MOS 6502.
//
// This is the M1 skeleton: the top-level interface is fixed per the project
// specification, all outputs are driven to known values, and the module lints
// clean under Verilator. Behavior will be filled in across milestones M3-M8.
//
// See DESIGN.md for clocking, reset, and architecture decisions, and
// docs/visual6502_mapping.md for the pin/signal correspondence with the
// Visual6502 reference.

`default_nettype none

module mos6502_core (
    input  logic        clk,
    input  logic        reset_n,

    input  logic        irq_n,
    input  logic        nmi_n,
    input  logic        ready,
    input  logic        so_n,

    output logic [15:0] address,
    input  logic [7:0]  data_in,
    output logic [7:0]  data_out,
    output logic        rw,
    output logic        sync
);

    // -------------------------------------------------------------------------
    // Skeleton state. Replaced by the real register file and FSM in M3+.
    // For now: a single counter so the testbench can see the core respond to
    // clk/reset and the outputs are driven, not floating.
    // -------------------------------------------------------------------------
    logic [15:0] pc_skel_q;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pc_skel_q <= 16'h0000;
        end else if (ready) begin
            pc_skel_q <= pc_skel_q + 16'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Outputs. All driven; no inferred latches.
    // -------------------------------------------------------------------------
    assign address  = pc_skel_q;
    assign data_out = 8'h00;
    assign rw       = 1'b1;   // skeleton only reads
    assign sync     = 1'b0;

    // -------------------------------------------------------------------------
    // Inputs not yet wired up. Tie off explicitly so Verilator does not warn
    // about unused signals once -Wall is on. Wrapped in a synthesis-safe
    // way (assignment to a discarded logic).
    // -------------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    wire _unused_inputs = &{1'b0, irq_n, nmi_n, so_n, data_in};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
