// SPDX-License-Identifier: MIT
//
// mos6502_registers — synchronous register file and staging FFs.
//
// Holds the 6502's architectural state (A, X, Y, S, P, IR, PC) plus the
// internal staging registers the control unit uses to build effective
// addresses (ad_lo, ad_hi, ptr, idx_carry, alu_in, rmw_target), branch
// staging (offset / cross / neg), and the interrupt-entry mode / NMI
// pending latch / SO edge tracker.
//
// All updates are gated by `ready` and synchronous on the rising edge of
// `clk`. Async-active-low reset.
//
// The control unit hands in the per-cycle action signals (commit_*, flag_*,
// etc.) and data sources; this module multiplexes them into the registers
// using the same case-on-state-q logic that lived in the monolithic core
// before this refactor.

`default_nettype none

module mos6502_registers
    import mos6502_state_pkg::*;
    import mos6502_decode_pkg::*;
    import mos6502_alu_pkg::*;
(
    input  logic        clk,
    input  logic        reset_n,
    input  logic        ready,

    // Pins (for edge detectors).
    input  logic        nmi_n,
    input  logic        so_n,
    input  logic        irq_n,        // unused here, but kept for symmetry

    // Live combinational inputs from the control unit.
    input  state_e      state_d,           // next FSM state
    input  logic [7:0]  data_in,           // bus read input
    input  logic [15:0] address_live,      // current cycle's AB (for rmw_target latch)

    // Decode (current IR).
    input  addr_mode_e  am,
    input  op_kind_e    opk,

    // ALU results and combo ALU results.
    input  alu_op_e     alu_op,
    input  logic [7:0]  alu_result,
    input  logic        alu_co,
    input  logic [7:0]  combo_result,
    input  logic        combo_co,
    input  logic        combo_ov,
    input  logic        combo_writes_a,
    input  logic        is_combined_rmw,

    // Indexed-addressing helpers.
    input  logic [7:0]  idx_value,
    input  logic [8:0]  adlo_plus_idx,

    // Commit / flag-update signals (control unit).
    input  logic        load_commit,
    input  logic [2:0]  load_target,
    input  logic        alu_commit_a,
    input  logic        alu_commit_acc,
    input  logic        alu_commit_xy,
    input  logic        alu_commit_imm_a,
    input  logic        alu_commit_imm_x,
    input  logic [7:0]  imm_combo_result,
    input  logic        rmw_latch,

    input  logic        xfer_active,
    input  logic [7:0]  xfer_value,
    input  logic [1:0]  xfer_dst,
    input  logic        xfer_upd_nz,

    input  logic        flag_active,
    input  logic        flag_update_nz,
    input  logic        flag_update_c,
    input  logic        flag_update_v,
    input  logic [7:0]  nz_value,
    input  logic        v_value,
    input  logic        c_value,
    input  logic        use_overrides,
    input  logic        n_override,
    input  logic        v_override,

    // Unstable undocumented opcode commits.
    input  logic        las_commit,
    input  logic [7:0]  las_value,
    input  logic        tas_s_commit,

    // Outputs.
    output logic [7:0]  a_q,
    output logic [7:0]  x_q,
    output logic [7:0]  y_q,
    output logic [7:0]  s_q,
    output logic [7:0]  p_q,
    output logic [7:0]  ir_q,
    output logic [15:0] pc_q,
    output logic [7:0]  ad_lo_q,
    output logic [7:0]  ad_hi_q,
    output logic [7:0]  ptr_q,
    output logic        idx_carry_q,
    output logic [7:0]  alu_in_q,
    output logic [15:0] rmw_target_q,
    output logic [7:0]  branch_offset_q,
    output logic        branch_cross_q,
    output logic        branch_neg_q,
    output int_mode_e   int_mode_q,
    output logic        nmi_pending_q,
    output state_e      state_q
);

    logic nmi_n_prev_q;
    logic so_n_prev_q;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state_q          <= S_RESET_0;
            a_q              <= 8'h00;
            x_q              <= 8'h00;
            y_q              <= 8'h00;
            s_q              <= 8'h00;
            p_q              <= 8'h24;
            ir_q             <= 8'h00;
            pc_q             <= 16'h0000;
            ad_lo_q          <= 8'h00;
            ad_hi_q          <= 8'h00;
            ptr_q            <= 8'h00;
            idx_carry_q      <= 1'b0;
            alu_in_q         <= 8'h00;
            rmw_target_q     <= 16'h0000;
            branch_offset_q  <= 8'h00;
            branch_cross_q   <= 1'b0;
            branch_neg_q     <= 1'b0;
            int_mode_q       <= INT_RESET;
            nmi_n_prev_q     <= 1'b1;
            nmi_pending_q    <= 1'b0;
            so_n_prev_q      <= 1'b1;
        end else if (ready) begin
            // ------------------ pin edge detectors ------------------
            nmi_n_prev_q <= nmi_n;
            so_n_prev_q  <= so_n;
            if (nmi_n_prev_q && !nmi_n) nmi_pending_q <= 1'b1;
            if (so_n_prev_q  && !so_n)  p_q[6] <= 1'b1;

            // ------------------ state advance ------------------------
            state_q <= state_d;

            // ------------------ reset sequence specifics -------------
            unique case (state_q)
                S_RESET_1, S_RESET_2, S_RESET_3: s_q <= s_q - 8'h01;
                S_RESET_4: pc_q[7:0]  <= data_in;
                S_RESET_5: pc_q[15:8] <= data_in;
                default: ;
            endcase

            // ------------------ FETCH / addressing-mode bookkeeping --
            unique case (state_q)
                S_FETCH: begin
                    if (nmi_pending_q) begin
                        int_mode_q <= INT_NMI;
                    end else if (!irq_n && !p_q[2]) begin
                        int_mode_q <= INT_IRQ;
                    end else begin
                        ir_q <= data_in;
                        pc_q <= pc_q + 16'd1;
                        if (data_in == 8'h00) int_mode_q <= INT_BRK;
                    end
                end
                S_IMM_RW: pc_q <= pc_q + 16'd1;
                S_PUSH_T2: s_q <= s_q - 8'h01;
                S_PULL_T3: s_q <= s_q + 8'h01;
                S_JSR_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JSR_PUSH_PCH, S_JSR_PUSH_PCL: s_q <= s_q - 8'h01;
                S_JSR_HI: pc_q <= {data_in, ad_lo_q};
                S_RTS_PULL_PCL: begin
                    pc_q[7:0] <= data_in;
                    s_q       <= s_q + 8'h01;
                end
                S_RTS_PULL_PCH: begin
                    pc_q[15:8] <= data_in;
                    s_q        <= s_q + 8'h01;
                end
                S_RTS_INC: pc_q <= pc_q + 16'd1;
                S_RTI_PULL_P: begin
                    p_q <= (data_in & 8'hEF) | 8'h20;
                    s_q <= s_q + 8'h01;
                end
                S_RTI_PULL_PCL: begin
                    pc_q[7:0] <= data_in;
                    s_q       <= s_q + 8'h01;
                end
                S_RTI_PULL_PCH: begin
                    pc_q[15:8] <= data_in;
                    s_q        <= s_q + 8'h01;
                end
                S_BR_OFFSET: begin
                    branch_offset_q <= data_in;
                    branch_neg_q    <= data_in[7];
                    if (data_in[7]) begin
                        branch_cross_q <= ((pc_q[7:0] + 8'h01) < (~data_in + 8'h01));
                    end else begin
                        branch_cross_q <= (({1'b0, pc_q[7:0] + 8'h01} +
                                            {1'b0, data_in}) > 9'h0FF);
                    end
                    pc_q <= pc_q + 16'd1;
                end
                S_BR_TAKEN: pc_q[7:0] <= pc_q[7:0] + branch_offset_q;
                S_BR_FIXUP: begin
                    if (branch_neg_q) pc_q[15:8] <= pc_q[15:8] - 8'h01;
                    else              pc_q[15:8] <= pc_q[15:8] + 8'h01;
                end
                S_JMP_ABS_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JMP_ABS_HI: pc_q <= {data_in, ad_lo_q};
                S_JMP_IND_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JMP_IND_HI: begin
                    ad_hi_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JMP_IND_PCL: pc_q[7:0]  <= data_in;
                S_JMP_IND_PCH: pc_q[15:8] <= data_in;
                S_INT_T1: if (int_mode_q == INT_BRK) pc_q <= pc_q + 16'd1;
                S_INT_PUSH_PCH, S_INT_PUSH_PCL: s_q <= s_q - 8'h01;
                S_INT_PUSH_P: begin
                    s_q    <= s_q - 8'h01;
                    p_q[2] <= 1'b1;
                end
                S_INT_VEC_LO: pc_q[7:0] <= data_in;
                S_INT_VEC_HI: begin
                    pc_q[15:8] <= data_in;
                    if (int_mode_q == INT_NMI) nmi_pending_q <= 1'b0;
                end

                S_ZP_ADDR, S_ZPI_ADDR: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_ZPI_DUMMY: ad_lo_q <= ad_lo_q + idx_value;
                S_INDX_ZP, S_INDY_ZP: begin
                    ptr_q <= data_in;
                    pc_q  <= pc_q + 16'd1;
                end
                S_ABS_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_ABS_HI: begin
                    ad_hi_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_ABSI_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_ABSI_HI: begin
                    ad_hi_q     <= data_in;
                    pc_q        <= pc_q + 16'd1;
                    ad_lo_q     <= adlo_plus_idx[7:0];
                    idx_carry_q <= adlo_plus_idx[8];
                end
                S_ABSI_DUMMY: if (idx_carry_q) ad_hi_q <= ad_hi_q + 8'h01;
                S_INDX_DUMMY: ptr_q   <= ptr_q + x_q;
                S_INDX_LO:    ad_lo_q <= data_in;
                S_INDX_HI:    ad_hi_q <= data_in;
                S_INDY_LO:    ad_lo_q <= data_in;
                S_INDY_HI: begin
                    ad_hi_q     <= data_in;
                    ad_lo_q     <= adlo_plus_idx[7:0];
                    idx_carry_q <= adlo_plus_idx[8];
                end
                S_INDY_DUMMY: if (idx_carry_q) ad_hi_q <= ad_hi_q + 8'h01;
                default: ;
            endcase

            // ------------------ RMW staging ----------------------------
            if (rmw_latch) begin
                alu_in_q     <= data_in;
                rmw_target_q <= address_live;
            end

            // ------------------ load / ALU / xfer / flag commits -----
            if (load_commit) begin
                unique case (load_target)
                    3'b000: a_q <= data_in;
                    3'b001: x_q <= data_in;
                    3'b010: y_q <= data_in;
                    3'b011: begin a_q <= data_in; x_q <= data_in; end
                    default: ;
                endcase
            end
            if (alu_commit_a || alu_commit_acc) a_q <= alu_result;
            if ((state_q == S_RMW_WRITE) && is_combined_rmw && combo_writes_a)
                a_q <= combo_result;
            if (alu_commit_xy) begin
                unique case (ir_q)
                    8'hE8, 8'hCA: x_q <= alu_result;
                    8'hC8, 8'h88: y_q <= alu_result;
                    default: ;
                endcase
            end
            if (xfer_active) begin
                unique case (xfer_dst)
                    2'b00: a_q <= xfer_value;
                    2'b01: x_q <= xfer_value;
                    2'b10: y_q <= xfer_value;
                    2'b11: s_q <= xfer_value;
                endcase
            end
            if (state_q == S_PULL_T3) begin
                if (ir_q == 8'h68) begin
                    a_q    <= data_in;
                    p_q[1] <= (data_in == 8'h00);
                    p_q[7] <= data_in[7];
                end else if (ir_q == 8'h28) begin
                    p_q <= (data_in & 8'hEF) | 8'h20;
                end
            end
            if (flag_active) begin
                unique case (ir_q)
                    8'h18: p_q[0] <= 1'b0;
                    8'h38: p_q[0] <= 1'b1;
                    8'h58: p_q[2] <= 1'b0;
                    8'h78: p_q[2] <= 1'b1;
                    8'hD8: p_q[3] <= 1'b0;
                    8'hF8: p_q[3] <= 1'b1;
                    8'hB8: p_q[6] <= 1'b0;
                    default: ;
                endcase
            end
            if (flag_update_nz) begin
                p_q[1] <= (nz_value == 8'h00);
                p_q[7] <= (use_overrides && n_override) ? data_in[7] : nz_value[7];
            end
            if (flag_update_c) p_q[0] <= c_value;
            if (flag_update_v) p_q[6] <= (use_overrides && v_override) ? data_in[6] : v_value;
            if (xfer_active && xfer_upd_nz) begin
                p_q[1] <= (xfer_value == 8'h00);
                p_q[7] <= xfer_value[7];
            end
            if (alu_commit_imm_a) a_q <= imm_combo_result;
            if (alu_commit_imm_x) x_q <= imm_combo_result;

            // LAS: write A, X, S simultaneously with data_in & S.
            if (las_commit) begin
                a_q <= las_value;
                x_q <= las_value;
                s_q <= las_value;
            end
            // TAS: S = A & X at the store cycle.
            if (tas_s_commit) s_q <= a_q & x_q;
        end
    end

    // verilator lint_off UNUSEDSIGNAL
    wire _unused = &{1'b0, am, opk, alu_op, alu_co, combo_co, combo_ov};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
