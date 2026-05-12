// SPDX-License-Identifier: MIT
//
// mos6502_core — synthesizable 6502 CPU.
//
// Single-edge synchronous, one `clk` rising edge = one bus cycle. The state
// machine drives all externally visible behavior (AB, RW, sync, data_out)
// combinationally from the current state and register file, and architectural
// state updates on the rising edge.
//
// Coverage at M3: reset (6 cycles + first opcode fetch) and NOP ($EA).
// Other opcodes recognised by mos6502_decode are routed to a generic
// "unimplemented" handler that does a 2-cycle NOP-style sequence so the bus
// stays well-defined while later milestones fill in real behavior.
//
// See DESIGN.md for the architectural decisions, docs/visual6502_mapping.md
// for the Visual6502 signal correspondence.

`default_nettype none

module mos6502_core
    import mos6502_decode_pkg::*;
(
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
    // FSM states.
    //
    // Reset takes 6 cycles before the first sync. Cycle layout follows the
    // Visual6502 reset trace:
    //   R0: AB = PC (power-on PC; in this RTL, initialized to 0)
    //   R1: AB = $01,S (suppressed PCH push), S--
    //   R2: AB = $01,S (suppressed PCL push), S--
    //   R3: AB = $01,S (suppressed P push),   S--
    //   R4: AB = $FFFC, latch PCL <= DB
    //   R5: AB = $FFFD, latch PCH <= DB
    //   then S_FETCH (T0), sync = 1.
    // -------------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_RESET_0,
        S_RESET_1,
        S_RESET_2,
        S_RESET_3,
        S_RESET_4,
        S_RESET_5,
        S_FETCH,
        S_T1_DUMMY,    // T1 for 2-cycle implied / unimplemented opcodes
        S_HALT         // unused at M3
    } state_e;

    state_e state_q;

    // Architectural registers.
    logic [7:0]  a_q;
    logic [7:0]  x_q;
    logic [7:0]  y_q;
    logic [7:0]  s_q;
    logic [7:0]  p_q;
    logic [7:0]  ir_q;
    logic [15:0] pc_q;

    // Decode outputs (combinational from ir_q).
    addr_mode_e  am;
    op_kind_e    opk;

    mos6502_decode u_decode (
        .ir        (ir_q),
        .addr_mode (am),
        .op_kind   (opk)
    );

    // -------------------------------------------------------------------------
    // Bus output and next-state — combinational from state_q and registers.
    // -------------------------------------------------------------------------
    logic [15:0] address_d;
    logic [7:0]  data_out_d;
    logic        rw_d;
    logic        sync_d;
    state_e      state_d;

    always_comb begin
        // Defaults: read at PC, no sync.
        address_d  = pc_q;
        data_out_d = 8'h00;
        rw_d       = 1'b1;
        sync_d     = 1'b0;
        state_d    = state_q;

        unique case (state_q)
            S_RESET_0: begin
                address_d = pc_q;
                state_d   = S_RESET_1;
            end
            S_RESET_1: begin
                address_d = {8'h01, s_q};
                state_d   = S_RESET_2;
            end
            S_RESET_2: begin
                address_d = {8'h01, s_q};
                state_d   = S_RESET_3;
            end
            S_RESET_3: begin
                address_d = {8'h01, s_q};
                state_d   = S_RESET_4;
            end
            S_RESET_4: begin
                address_d = 16'hFFFC;
                state_d   = S_RESET_5;
            end
            S_RESET_5: begin
                address_d = 16'hFFFD;
                state_d   = S_FETCH;
            end

            S_FETCH: begin
                address_d = pc_q;
                sync_d    = 1'b1;
                // Next state is decided by the opcode that will be latched
                // into ir_q at this clock edge. We dispatch on the live
                // `data_in` (== the opcode we're fetching this cycle).
                unique case (data_in)
                    8'hEA:   state_d = S_T1_DUMMY;   // NOP
                    default: state_d = S_T1_DUMMY;   // unimplemented → 2-cycle NOP
                endcase
            end

            S_T1_DUMMY: begin
                // Discard read at PC, then fetch the next opcode.
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            S_HALT: begin
                address_d = pc_q;
                state_d   = S_HALT;
            end

            default: begin
                state_d = S_RESET_0;
            end
        endcase
    end

    assign address  = address_d;
    assign data_out = data_out_d;
    assign rw       = rw_d;
    assign sync     = sync_d;

    // -------------------------------------------------------------------------
    // Synchronous state and register updates.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state_q <= S_RESET_0;
            a_q     <= 8'h00;
            x_q     <= 8'h00;
            y_q     <= 8'h00;
            s_q     <= 8'h00;  // matches Visual6502's effective power-on S
            p_q     <= 8'h24;  // I set, unused bit 5 set (B/C/D/N/V/Z all 0)
            ir_q    <= 8'h00;
            pc_q    <= 16'h0000;
        end else if (ready) begin
            state_q <= state_d;

            unique case (state_q)
                S_RESET_1, S_RESET_2, S_RESET_3: begin
                    // The "suppressed pushes" still decrement S.
                    s_q <= s_q - 8'h01;
                end
                S_RESET_4: begin
                    // The byte fetched at $FFFC latches into PCL at end of cycle.
                    pc_q[7:0] <= data_in;
                end
                S_RESET_5: begin
                    // PCH from $FFFD.
                    pc_q[15:8] <= data_in;
                end
                S_FETCH: begin
                    ir_q <= data_in;
                    pc_q <= pc_q + 16'd1;
                end
                S_T1_DUMMY: begin
                    // 2-cycle implied / NOP: PC is already at "next opcode" from
                    // the FETCH increment. No further updates here.
                end
                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Tie-offs for inputs not yet consumed (silence Verilator UNUSEDSIGNAL).
    // -------------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    wire _unused = &{1'b0, irq_n, nmi_n, so_n, am, opk, a_q, x_q, y_q, p_q};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
