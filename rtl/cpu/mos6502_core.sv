// SPDX-License-Identifier: MIT
//
// mos6502_core — synthesizable 6502 CPU (top-level wirer).
//
// Single-edge synchronous: one `clk` rising edge advances the bus by exactly
// one cycle. AB / RW / SYNC / data_out are combinational from the current
// FSM state and register file; architectural state updates at the rising
// edge.
//
// Submodules:
//   mos6502_pkg        : shared typedefs (addr modes, op kinds, ALU ops, FSM state)
//   mos6502_alu        : combinational ALU
//   mos6502_decode     : opcode → (addr_mode, op_kind)
//   mos6502_registers  : architectural + staging FFs
//   mos6502_core       : the rest (FSM, commit-signal generation, bus output drive)
//
// The core's combinational always_comb produces:
//   * state_d            (next-state for the FSM)
//   * address_d / data_out_d / rw_d / sync_d  (external bus drive)
//   * all the commit / flag-update signals consumed by mos6502_registers.
//
// See DESIGN.md for cycle-model and clocking rationale, and
// docs/visual6502_mapping.md for the Visual6502 signal correspondence.

`default_nettype none

module mos6502_core
    import mos6502_decode_pkg::*;
    import mos6502_alu_pkg::*;
    import mos6502_state_pkg::*;
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

    // ------------------------------------------------------------------------
    // Register-file outputs (architectural + staging).
    // ------------------------------------------------------------------------
    logic [7:0]  a_q, x_q, y_q, s_q, p_q, ir_q;
    logic [15:0] pc_q;
    logic [7:0]  ad_lo_q, ad_hi_q, ptr_q;
    logic        idx_carry_q;
    logic [7:0]  alu_in_q;
    logic [15:0] rmw_target_q;
    logic [7:0]  branch_offset_q;
    logic        branch_cross_q;
    logic        branch_neg_q;
    int_mode_e   int_mode_q;
    logic        nmi_pending_q;
    state_e      state_q;

    // ------------------------------------------------------------------------
    // Decode (current IR and look-ahead on incoming DB during S_FETCH).
    // ------------------------------------------------------------------------
    addr_mode_e am, am_next;
    op_kind_e   opk, opk_next;

    mos6502_decode u_decode (
        .ir        (ir_q),
        .addr_mode (am),
        .op_kind   (opk)
    );
    mos6502_decode u_decode_next (
        .ir        (data_in),
        .addr_mode (am_next),
        .op_kind   (opk_next)
    );

    logic is_rmw_mem;
    assign is_rmw_mem = (opk == OP_RMW) && (am != AM_ACC) && (am != AM_IMPL);
    logic is_store;
    assign is_store = (opk == OP_STORE);
    logic indexed_dummy_skippable;
    assign indexed_dummy_skippable = !is_store && !is_rmw_mem && !idx_carry_q;

    // High byte of the *base* address (pre-fixup) used by the unstable
    // store-undoc family (AHX/SHX/SHY/TAS): the value stored is
    // reg & (base_addr_hi + 1).  By the time we reach the *_RW state,
    // ad_hi_q has already been fixed up if a page crossed; recover the
    // original via ad_hi - idx_carry.
    logic [7:0] base_ad_hi_plus_one;
    assign base_ad_hi_plus_one = ad_hi_q - {7'b0, idx_carry_q} + 8'h01;

    // Target register for LD?/ST? from IR[1:0]. 00=Y, 01=A, 10=X, 11=SAX/LAX.
    // The unstable store family ($9B/$9C/$9E/$9F/$93) is special-cased.
    logic [7:0] store_src;
    always_comb begin
        unique case (ir_q)
            8'h9F, 8'h93: store_src = a_q & x_q & base_ad_hi_plus_one; // AHX
            8'h9B:        store_src = (a_q & x_q) & base_ad_hi_plus_one; // TAS
            8'h9E:        store_src = x_q & base_ad_hi_plus_one;       // SHX
            8'h9C:        store_src = y_q & base_ad_hi_plus_one;       // SHY
            default: begin
                unique case (ir_q[1:0])
                    2'b00:   store_src = y_q;
                    2'b01:   store_src = a_q;
                    2'b10:   store_src = x_q;
                    2'b11:   store_src = a_q & x_q;     // SAX
                    default: store_src = 8'h00;
                endcase
            end
        endcase
    end
    logic [2:0] load_target;
    always_comb begin
        unique case (ir_q[1:0])
            2'b00:   load_target = 3'b010;
            2'b01:   load_target = 3'b000;
            2'b10:   load_target = 3'b001;
            2'b11:   load_target = 3'b011;
            default: load_target = 3'b000;
        endcase
    end

    logic [7:0] idx_value;
    always_comb begin
        unique case (am)
            AM_ZPX, AM_ABSX, AM_INDX: idx_value = x_q;
            AM_ZPY, AM_ABSY, AM_INDY: idx_value = y_q;
            default:                  idx_value = 8'h00;
        endcase
    end

    logic [8:0] adlo_plus_idx;
    assign adlo_plus_idx = {1'b0, ad_lo_q} + {1'b0, idx_value};

    // ------------------------------------------------------------------------
    // ALU op + operand selection.
    // ------------------------------------------------------------------------
    function automatic alu_op_e ir_to_alu_op(input logic [7:0] ir);
        unique case (ir)
            8'h09, 8'h05, 8'h15, 8'h0D, 8'h1D, 8'h19, 8'h01, 8'h11: ir_to_alu_op = ALU_ORA;
            8'h29, 8'h25, 8'h35, 8'h2D, 8'h3D, 8'h39, 8'h21, 8'h31: ir_to_alu_op = ALU_AND;
            8'h49, 8'h45, 8'h55, 8'h4D, 8'h5D, 8'h59, 8'h41, 8'h51: ir_to_alu_op = ALU_EOR;
            8'h69, 8'h65, 8'h75, 8'h6D, 8'h7D, 8'h79, 8'h61, 8'h71: ir_to_alu_op = ALU_ADC;
            8'hC9, 8'hC5, 8'hD5, 8'hCD, 8'hDD, 8'hD9, 8'hC1, 8'hD1,
            8'hE0, 8'hE4, 8'hEC, 8'hC0, 8'hC4, 8'hCC:               ir_to_alu_op = ALU_CMP;
            8'hE9, 8'hE5, 8'hF5, 8'hED, 8'hFD, 8'hF9, 8'hE1, 8'hF1: ir_to_alu_op = ALU_SBC;
            8'h24, 8'h2C:                                            ir_to_alu_op = ALU_BIT;
            8'h0A, 8'h06, 8'h16, 8'h0E, 8'h1E,
            8'h03, 8'h07, 8'h0F, 8'h13, 8'h17, 8'h1B, 8'h1F:         ir_to_alu_op = ALU_ASL;
            8'h2A, 8'h26, 8'h36, 8'h2E, 8'h3E,
            8'h23, 8'h27, 8'h2F, 8'h33, 8'h37, 8'h3B, 8'h3F:         ir_to_alu_op = ALU_ROL;
            8'h4A, 8'h46, 8'h56, 8'h4E, 8'h5E,
            8'h43, 8'h47, 8'h4F, 8'h53, 8'h57, 8'h5B, 8'h5F:         ir_to_alu_op = ALU_LSR;
            8'h6A, 8'h66, 8'h76, 8'h6E, 8'h7E,
            8'h63, 8'h67, 8'h6F, 8'h73, 8'h77, 8'h7B, 8'h7F:         ir_to_alu_op = ALU_ROR;
            8'hE6, 8'hF6, 8'hEE, 8'hFE, 8'hE8, 8'hC8,
            8'hE3, 8'hE7, 8'hEF, 8'hF3, 8'hF7, 8'hFB, 8'hFF:         ir_to_alu_op = ALU_INC;
            8'hC6, 8'hD6, 8'hCE, 8'hDE, 8'hCA, 8'h88,
            8'hC3, 8'hC7, 8'hCF, 8'hD3, 8'hD7, 8'hDB, 8'hDF:         ir_to_alu_op = ALU_DEC;
            default:                                                  ir_to_alu_op = ALU_NONE;
        endcase
    endfunction

    alu_op_e    alu_op;
    logic [7:0] alu_a;
    logic [7:0] alu_b;
    logic [7:0] alu_result;
    logic       alu_co, alu_ov, alu_zr, alu_ne;

    logic [7:0] alu_a_sel;
    always_comb begin
        if ((state_q == S_RMW_DUMMY_WRITE) || (state_q == S_RMW_WRITE)) begin
            alu_a_sel = alu_in_q;
        end else if ((state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_IMPL)) begin
            unique case (ir_q)
                8'hE8, 8'hCA: alu_a_sel = x_q;
                8'hC8, 8'h88: alu_a_sel = y_q;
                default:      alu_a_sel = 8'h00;
            endcase
        end else if ((state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_ACC)) begin
            alu_a_sel = a_q;
        end else begin
            unique case (ir_q)
                8'hE0, 8'hE4, 8'hEC: alu_a_sel = x_q; // CPX
                8'hC0, 8'hC4, 8'hCC: alu_a_sel = y_q; // CPY
                default:              alu_a_sel = a_q;
            endcase
        end
    end

    assign alu_op = ir_to_alu_op(ir_q);
    assign alu_a  = alu_a_sel;
    assign alu_b  = data_in;

    mos6502_alu u_alu (
        .op        (alu_op),
        .a         (alu_a),
        .b         (alu_b),
        .carry_in  (p_q[0]),
        .decimal   (p_q[3]),
        .result    (alu_result),
        .carry_out (alu_co),
        .overflow  (alu_ov),
        .zero      (alu_zr),
        .negative  (alu_ne)
    );

    // Combo (second) ALU for the undocumented RMW+ALU family.
    function automatic alu_op_e ir_to_combo_op(input logic [7:0] ir);
        unique case (ir)
            8'hC3, 8'hC7, 8'hCF, 8'hD3, 8'hD7, 8'hDB, 8'hDF: ir_to_combo_op = ALU_CMP;
            8'hE3, 8'hE7, 8'hEF, 8'hF3, 8'hF7, 8'hFB, 8'hFF: ir_to_combo_op = ALU_SBC;
            8'h03, 8'h07, 8'h0F, 8'h13, 8'h17, 8'h1B, 8'h1F: ir_to_combo_op = ALU_ORA;
            8'h23, 8'h27, 8'h2F, 8'h33, 8'h37, 8'h3B, 8'h3F: ir_to_combo_op = ALU_AND;
            8'h43, 8'h47, 8'h4F, 8'h53, 8'h57, 8'h5B, 8'h5F: ir_to_combo_op = ALU_EOR;
            8'h63, 8'h67, 8'h6F, 8'h73, 8'h77, 8'h7B, 8'h7F: ir_to_combo_op = ALU_ADC;
            default:                                          ir_to_combo_op = ALU_NONE;
        endcase
    endfunction

    alu_op_e combo_op;
    logic    combo_uses_alu_co;
    logic    combo_writes_a;
    logic [7:0] combo_result;
    logic       combo_co, combo_ov, combo_zr, combo_ne;
    assign combo_op = ir_to_combo_op(ir_q);
    always_comb begin
        unique case (ir_q)
            8'h63, 8'h67, 8'h6F, 8'h73, 8'h77, 8'h7B, 8'h7F: combo_uses_alu_co = 1'b1;
            default:                                          combo_uses_alu_co = 1'b0;
        endcase
        unique case (combo_op)
            ALU_CMP, ALU_NONE: combo_writes_a = 1'b0;
            default:           combo_writes_a = 1'b1;
        endcase
    end

    mos6502_alu u_alu_combo (
        .op        (combo_op),
        .a         (a_q),
        .b         (alu_result),
        .carry_in  (combo_uses_alu_co ? alu_co : p_q[0]),
        .decimal   (1'b0),
        .result    (combo_result),
        .carry_out (combo_co),
        .overflow  (combo_ov),
        .zero      (combo_zr),
        .negative  (combo_ne)
    );

    logic is_combined_rmw;
    assign is_combined_rmw = (combo_op != ALU_NONE);

    // Undocumented immediate ALU combos (ANC / ALR / ARR / AXS / XAA).
    logic is_imm_undoc_combo;
    always_comb begin
        unique case (ir_q)
            8'h0B, 8'h2B, 8'h4B, 8'h6B, 8'hCB, 8'h8B: is_imm_undoc_combo = 1'b1;
            default:                                   is_imm_undoc_combo = 1'b0;
        endcase
    end

    logic [7:0] imm_combo_result;
    logic [7:0] a_and_imm;
    logic [8:0] axs_sub;
    // XAA "magic constant" — varies by chip; $EE is a documented common value.
    localparam logic [7:0] XAA_CONST = 8'hEE;
    assign a_and_imm = a_q & data_in;
    assign axs_sub   = {1'b0, a_q & x_q} + {1'b0, ~data_in} + 9'd1;
    always_comb begin
        unique case (ir_q)
            8'h0B, 8'h2B: imm_combo_result = a_and_imm;
            8'h4B:        imm_combo_result = {1'b0, a_and_imm[7:1]};
            8'h6B:        imm_combo_result = {p_q[0], a_and_imm[7:1]};
            8'hCB:        imm_combo_result = axs_sub[7:0];
            8'h8B:        imm_combo_result = (a_q | XAA_CONST) & x_q & data_in; // XAA
            default:      imm_combo_result = 8'h00;
        endcase
    end

    // ------------------------------------------------------------------------
    // FSM transitions and bus output drive (combinational).
    // ------------------------------------------------------------------------
    logic [15:0] address_d;
    logic [7:0]  data_out_d;
    logic        rw_d;
    logic        sync_d;
    state_e      state_d;

    function automatic state_e first_state_for(input addr_mode_e m,
                                               input op_kind_e   o);
        unique case (o)
            OP_JSR:    first_state_for = S_JSR_LO;
            OP_RTS:    first_state_for = S_RTS_T1;
            OP_RTI:    first_state_for = S_RTI_T1;
            OP_BRK:    first_state_for = S_INT_T1;
            OP_PUSH:   first_state_for = S_PUSH_T1;
            OP_PULL:   first_state_for = S_PULL_T1;
            OP_BRANCH: first_state_for = S_BR_OFFSET;
            OP_JMP: begin
                if (m == AM_IND) first_state_for = S_JMP_IND_LO;
                else             first_state_for = S_JMP_ABS_LO;
            end
            default: begin
                unique case (m)
                    AM_IMPL: first_state_for = S_T1_DUMMY;
                    AM_ACC:  first_state_for = S_T1_DUMMY;
                    AM_IMM:  first_state_for = S_IMM_RW;
                    AM_ZP:   first_state_for = S_ZP_ADDR;
                    AM_ZPX:  first_state_for = S_ZPI_ADDR;
                    AM_ZPY:  first_state_for = S_ZPI_ADDR;
                    AM_ABS:  first_state_for = S_ABS_LO;
                    AM_ABSX: first_state_for = S_ABSI_LO;
                    AM_ABSY: first_state_for = S_ABSI_LO;
                    AM_INDX: first_state_for = S_INDX_ZP;
                    AM_INDY: first_state_for = S_INDY_ZP;
                    default: first_state_for = S_T1_DUMMY;
                endcase
            end
        endcase
    endfunction

    state_e rw_next;
    assign rw_next = is_rmw_mem ? S_RMW_DUMMY_WRITE : S_FETCH;

    function automatic logic branch_taken_now();
        logic flag_val;
        unique case (ir_q[7:6])
            2'b00:   flag_val = p_q[7];
            2'b01:   flag_val = p_q[6];
            2'b10:   flag_val = p_q[0];
            2'b11:   flag_val = p_q[1];
            default: flag_val = 1'b0;
        endcase
        branch_taken_now = (flag_val == ir_q[5]);
    endfunction

    always_comb begin
        address_d  = pc_q;
        data_out_d = 8'h00;
        rw_d       = 1'b1;
        sync_d     = 1'b0;
        state_d    = state_q;

        unique case (state_q)
            S_RESET_0: begin address_d = pc_q;            state_d = S_RESET_1; end
            S_RESET_1: begin address_d = {8'h01, s_q};    state_d = S_RESET_2; end
            S_RESET_2: begin address_d = {8'h01, s_q};    state_d = S_RESET_3; end
            S_RESET_3: begin address_d = {8'h01, s_q};    state_d = S_RESET_4; end
            S_RESET_4: begin address_d = 16'hFFFC;        state_d = S_RESET_5; end
            S_RESET_5: begin address_d = 16'hFFFD;        state_d = S_FETCH;   end

            S_FETCH: begin
                address_d = pc_q;
                if (nmi_pending_q || (!irq_n && !p_q[2])) begin
                    sync_d  = 1'b0;
                    state_d = S_INT_T0;
                end else begin
                    sync_d  = 1'b1;
                    state_d = first_state_for(am_next, opk_next);
                end
            end

            S_T1_DUMMY: begin address_d = pc_q; state_d = S_FETCH; end
            S_IMM_RW:   begin address_d = pc_q; state_d = S_FETCH; end

            S_ZP_ADDR:  begin address_d = pc_q;             state_d = S_ZP_RW;     end
            S_ZP_RW: begin
                address_d  = {8'h00, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_ZPI_ADDR:  begin address_d = pc_q;             state_d = S_ZPI_DUMMY; end
            S_ZPI_DUMMY: begin address_d = {8'h00, ad_lo_q}; state_d = S_ZPI_RW;    end
            S_ZPI_RW: begin
                address_d  = {8'h00, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_ABS_LO: begin address_d = pc_q; state_d = S_ABS_HI; end
            S_ABS_HI: begin address_d = pc_q; state_d = S_ABS_RW; end
            S_ABS_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_ABSI_LO:  begin address_d = pc_q; state_d = S_ABSI_HI;    end
            S_ABSI_HI:  begin address_d = pc_q; state_d = S_ABSI_DUMMY; end
            S_ABSI_DUMMY: begin
                address_d = {ad_hi_q, ad_lo_q};
                if (indexed_dummy_skippable) begin
                    rw_d    = 1'b1;
                    state_d = rw_next;
                end else begin
                    state_d = S_ABSI_RW;
                end
            end
            S_ABSI_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_INDX_ZP:    begin address_d = pc_q;                  state_d = S_INDX_DUMMY;end
            S_INDX_DUMMY: begin address_d = {8'h00, ptr_q};        state_d = S_INDX_LO;   end
            S_INDX_LO:    begin address_d = {8'h00, ptr_q};        state_d = S_INDX_HI;   end
            S_INDX_HI:    begin address_d = {8'h00, ptr_q + 8'h01};state_d = S_INDX_RW;   end
            S_INDX_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_INDY_ZP:    begin address_d = pc_q;                  state_d = S_INDY_LO;   end
            S_INDY_LO:    begin address_d = {8'h00, ptr_q};        state_d = S_INDY_HI;   end
            S_INDY_HI:    begin address_d = {8'h00, ptr_q + 8'h01};state_d = S_INDY_DUMMY;end
            S_INDY_DUMMY: begin
                address_d = {ad_hi_q, ad_lo_q};
                if (indexed_dummy_skippable) begin
                    rw_d    = 1'b1;
                    state_d = rw_next;
                end else begin
                    state_d = S_INDY_RW;
                end
            end
            S_INDY_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_RMW_DUMMY_WRITE: begin
                address_d  = rmw_target_q;
                rw_d       = 1'b0;
                data_out_d = alu_in_q;
                state_d    = S_RMW_WRITE;
            end
            S_RMW_WRITE: begin
                address_d  = rmw_target_q;
                rw_d       = 1'b0;
                data_out_d = is_combined_rmw ? alu_result : alu_result;
                // Note: regardless of combined RMW or plain RMW, the data
                // written to memory is alu_result (the shift/inc/dec value).
                // The combo result is the A-side, computed in u_alu_combo
                // and committed in mos6502_registers.
                state_d    = S_FETCH;
            end

            S_PUSH_T1: begin address_d = pc_q;             state_d = S_PUSH_T2; end
            S_PUSH_T2: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                data_out_d = (ir_q == 8'h08) ? (p_q | 8'h30) : a_q;
                state_d    = S_FETCH;
            end

            S_PULL_T1: begin address_d = pc_q;                  state_d = S_PULL_T2; end
            S_PULL_T2: begin address_d = {8'h01, s_q};          state_d = S_PULL_T3; end
            S_PULL_T3: begin address_d = {8'h01, s_q + 8'h01};  state_d = S_FETCH;   end

            S_JSR_LO:        begin address_d = pc_q;                  state_d = S_JSR_PEEK;     end
            S_JSR_PEEK:      begin address_d = {8'h01, s_q};          state_d = S_JSR_PUSH_PCH; end
            S_JSR_PUSH_PCH: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                data_out_d = pc_q[15:8];
                state_d    = S_JSR_PUSH_PCL;
            end
            S_JSR_PUSH_PCL: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                data_out_d = pc_q[7:0];
                state_d    = S_JSR_HI;
            end
            S_JSR_HI: begin address_d = pc_q; state_d = S_FETCH; end

            S_RTS_T1:         begin address_d = pc_q;                state_d = S_RTS_PEEK;     end
            S_RTS_PEEK:       begin address_d = {8'h01, s_q};        state_d = S_RTS_PULL_PCL; end
            S_RTS_PULL_PCL:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTS_PULL_PCH; end
            S_RTS_PULL_PCH:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTS_INC;     end
            S_RTS_INC:        begin address_d = pc_q;                state_d = S_FETCH;        end

            S_RTI_T1:         begin address_d = pc_q;                state_d = S_RTI_PEEK;    end
            S_RTI_PEEK:       begin address_d = {8'h01, s_q};        state_d = S_RTI_PULL_P;  end
            S_RTI_PULL_P:     begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTI_PULL_PCL;end
            S_RTI_PULL_PCL:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTI_PULL_PCH;end
            S_RTI_PULL_PCH:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_FETCH;       end

            S_INT_T0: begin address_d = pc_q; state_d = S_INT_T1;       end
            S_INT_T1: begin address_d = pc_q; state_d = S_INT_PUSH_PCH; end
            S_INT_PUSH_PCH: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                data_out_d = pc_q[15:8];
                state_d    = S_INT_PUSH_PCL;
            end
            S_INT_PUSH_PCL: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                data_out_d = pc_q[7:0];
                state_d    = S_INT_PUSH_P;
            end
            S_INT_PUSH_P: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                data_out_d = (int_mode_q == INT_BRK) ? (p_q | 8'h30)
                                                     : ((p_q & 8'hEF) | 8'h20);
                state_d    = S_INT_VEC_LO;
            end
            S_INT_VEC_LO: begin
                address_d = (int_mode_q == INT_NMI) ? 16'hFFFA : 16'hFFFE;
                state_d   = S_INT_VEC_HI;
            end
            S_INT_VEC_HI: begin
                address_d = (int_mode_q == INT_NMI) ? 16'hFFFB : 16'hFFFF;
                state_d   = S_FETCH;
            end

            S_BR_OFFSET: begin
                address_d = pc_q;
                state_d   = branch_taken_now() ? S_BR_TAKEN : S_FETCH;
            end
            S_BR_TAKEN: begin
                address_d = pc_q;
                state_d   = branch_cross_q ? S_BR_FIXUP : S_FETCH;
            end
            S_BR_FIXUP: begin
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            S_JMP_ABS_LO: begin address_d = pc_q; state_d = S_JMP_ABS_HI; end
            S_JMP_ABS_HI: begin address_d = pc_q; state_d = S_FETCH;      end
            S_JMP_IND_LO: begin address_d = pc_q; state_d = S_JMP_IND_HI; end
            S_JMP_IND_HI: begin address_d = pc_q; state_d = S_JMP_IND_PCL;end
            S_JMP_IND_PCL: begin address_d = {ad_hi_q, ad_lo_q};            state_d = S_JMP_IND_PCH; end
            S_JMP_IND_PCH: begin address_d = {ad_hi_q, ad_lo_q + 8'h01};    state_d = S_FETCH;        end

            S_HALT: begin address_d = pc_q; state_d = S_HALT; end

            default: state_d = S_RESET_0;
        endcase
    end

    // RDY freeze: writes commit even when ready==0, but reads pause.
    logic ready_advance;
    assign ready_advance = ready || !rw_d;

    assign address  = address_d;
    assign data_out = data_out_d;
    assign rw       = rw_d;
    assign sync     = sync_d;

    // ------------------------------------------------------------------------
    // Commit / flag-update signals consumed by mos6502_registers.
    // ------------------------------------------------------------------------
    logic in_rw_state;
    always_comb begin
        in_rw_state = (state_q == S_IMM_RW)
                    | (state_q == S_ZP_RW)
                    | (state_q == S_ZPI_RW)
                    | (state_q == S_ABS_RW)
                    | (state_q == S_ABSI_RW)
                    | (state_q == S_INDX_RW)
                    | (state_q == S_INDY_RW)
                    | ((state_q == S_ABSI_DUMMY) && indexed_dummy_skippable)
                    | ((state_q == S_INDY_DUMMY) && indexed_dummy_skippable);
    end

    logic is_alu_compute_cycle;
    assign is_alu_compute_cycle = in_rw_state && (opk == OP_ALU);
    logic is_rmw_read_cycle;
    assign is_rmw_read_cycle    = in_rw_state && is_rmw_mem;
    logic is_load_cycle;
    assign is_load_cycle        = in_rw_state && (opk == OP_LOAD);

    logic        xfer_active;
    logic [7:0]  xfer_value;
    logic [1:0]  xfer_dst;
    logic        xfer_upd_nz;
    always_comb begin
        xfer_active = (state_q == S_T1_DUMMY) && (opk == OP_XFER);
        unique case (ir_q)
            8'hAA: begin xfer_value = a_q; xfer_dst = 2'b01; xfer_upd_nz = 1'b1; end
            8'hA8: begin xfer_value = a_q; xfer_dst = 2'b10; xfer_upd_nz = 1'b1; end
            8'h8A: begin xfer_value = x_q; xfer_dst = 2'b00; xfer_upd_nz = 1'b1; end
            8'h98: begin xfer_value = y_q; xfer_dst = 2'b00; xfer_upd_nz = 1'b1; end
            8'hBA: begin xfer_value = s_q; xfer_dst = 2'b01; xfer_upd_nz = 1'b1; end
            8'h9A: begin xfer_value = x_q; xfer_dst = 2'b11; xfer_upd_nz = 1'b0; end
            default: begin xfer_value = 8'h00; xfer_dst = 2'b00; xfer_upd_nz = 1'b0; end
        endcase
    end

    logic implied_rmw_active;
    logic acc_rmw_active;
    logic flag_active;
    always_comb begin
        implied_rmw_active = (state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_IMPL);
        acc_rmw_active     = (state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_ACC);
        flag_active        = (state_q == S_T1_DUMMY) && (opk == OP_FLAG);
    end

    logic load_commit;
    logic alu_commit_a;
    logic alu_commit_xy;
    logic alu_commit_acc;
    logic alu_commit_imm_a;
    logic alu_commit_imm_x;
    logic rmw_latch;
    // Unstable-opcode side channels.
    logic       las_commit;     // LAS ($BB): write A=X=S=data&S
    logic [7:0] las_value;
    logic       tas_s_commit;   // TAS ($9B): S = A & X (no flags)
    logic flag_update_nz;
    logic flag_update_c;
    logic flag_update_v;
    logic [7:0] nz_value;
    logic       v_value;
    logic       c_value;
    logic       n_override;
    logic       v_override;
    logic       use_overrides;

    // LAS commit: at the load cycle of LAS, write A=X=S = data_in & S.
    assign las_value  = data_in & s_q;
    assign las_commit = in_rw_state && (ir_q == 8'hBB);
    // TAS S commit: at the store cycle of TAS, S = A & X.
    assign tas_s_commit = ((state_q == S_ABSI_RW) ||
                           ((state_q == S_ABSI_DUMMY) && indexed_dummy_skippable))
                          && (ir_q == 8'h9B);

    always_comb begin
        load_commit      = 1'b0;
        alu_commit_a     = 1'b0;
        alu_commit_xy    = 1'b0;
        alu_commit_acc   = 1'b0;
        alu_commit_imm_a = 1'b0;
        alu_commit_imm_x = 1'b0;
        rmw_latch        = 1'b0;
        flag_update_nz   = 1'b0;
        flag_update_c    = 1'b0;
        flag_update_v    = 1'b0;
        nz_value         = 8'h00;
        v_value          = 1'b0;
        c_value          = 1'b0;
        n_override       = 1'b0;
        v_override       = 1'b0;
        use_overrides    = 1'b0;

        if (las_commit) begin
            // LAS handles its own commit (A,X,S) and flags in the register
            // file; we just signal N/Z update from the LAS value.
            flag_update_nz = 1'b1;
            nz_value       = las_value;
        end else if (is_load_cycle) begin
            load_commit    = 1'b1;
            flag_update_nz = 1'b1;
            nz_value       = data_in;
        end else if (is_rmw_read_cycle) begin
            rmw_latch = 1'b1;
        end else if (is_alu_compute_cycle && is_imm_undoc_combo) begin
            flag_update_nz = 1'b1;
            nz_value       = imm_combo_result;
            unique case (ir_q)
                8'h0B, 8'h2B: begin
                    alu_commit_imm_a = 1'b1;
                    flag_update_c    = 1'b1;
                    c_value          = imm_combo_result[7];
                end
                8'h4B: begin
                    alu_commit_imm_a = 1'b1;
                    flag_update_c    = 1'b1;
                    c_value          = a_and_imm[0];
                end
                8'h6B: begin
                    alu_commit_imm_a = 1'b1;
                    flag_update_c    = 1'b1;
                    flag_update_v    = 1'b1;
                    c_value          = imm_combo_result[6];
                    v_value          = imm_combo_result[6] ^ imm_combo_result[5];
                end
                8'hCB: begin
                    alu_commit_imm_x = 1'b1;
                    flag_update_c    = 1'b1;
                    c_value          = axs_sub[8];
                end
                8'h8B: begin
                    // XAA: A = (A | const) & X & imm. No carry update.
                    alu_commit_imm_a = 1'b1;
                end
                default: ;
            endcase
        end else if (is_alu_compute_cycle) begin
            unique case (alu_op)
                ALU_ORA, ALU_AND, ALU_EOR: begin
                    alu_commit_a    = 1'b1;
                    flag_update_nz  = 1'b1;
                    nz_value        = alu_result;
                end
                ALU_ADC, ALU_SBC: begin
                    alu_commit_a    = 1'b1;
                    flag_update_nz  = 1'b1;
                    flag_update_c   = 1'b1;
                    flag_update_v   = 1'b1;
                    nz_value        = alu_result;
                    c_value         = alu_co;
                    v_value         = alu_ov;
                end
                ALU_CMP: begin
                    flag_update_nz  = 1'b1;
                    flag_update_c   = 1'b1;
                    nz_value        = alu_result;
                    c_value         = alu_co;
                end
                ALU_BIT: begin
                    flag_update_nz  = 1'b1;
                    flag_update_v   = 1'b1;
                    nz_value        = alu_result;
                    v_value         = data_in[6];
                    n_override      = 1'b1;
                    use_overrides   = 1'b1;
                end
                default: ;
            endcase
        end else if (state_q == S_RMW_WRITE) begin
            if (is_combined_rmw) begin
                flag_update_nz = 1'b1;
                nz_value       = combo_result;
                unique case (combo_op)
                    ALU_CMP: begin
                        flag_update_c = 1'b1;
                        c_value       = combo_co;
                    end
                    ALU_SBC, ALU_ADC: begin
                        flag_update_c = 1'b1;
                        flag_update_v = 1'b1;
                        c_value       = combo_co;
                        v_value       = combo_ov;
                    end
                    ALU_ORA, ALU_AND, ALU_EOR: begin
                        flag_update_c = 1'b1;
                        c_value       = alu_co;
                    end
                    default: ;
                endcase
            end else begin
                flag_update_nz = 1'b1;
                nz_value       = alu_result;
                unique case (alu_op)
                    ALU_ASL, ALU_LSR, ALU_ROL, ALU_ROR: begin
                        flag_update_c = 1'b1;
                        c_value       = alu_co;
                    end
                    default: ;
                endcase
            end
        end else if (acc_rmw_active) begin
            alu_commit_acc = 1'b1;
            flag_update_nz = 1'b1;
            nz_value       = alu_result;
            flag_update_c  = 1'b1;
            c_value        = alu_co;
        end else if (implied_rmw_active) begin
            alu_commit_xy  = 1'b1;
            flag_update_nz = 1'b1;
            nz_value       = alu_result;
        end
    end

    // ------------------------------------------------------------------------
    // Register file.
    // ------------------------------------------------------------------------
    // LAS / TAS commits are appended on top of the generic load_target /
    // store_src plumbing — they don't fit the per-register write-enable
    // model so the register file handles them as separate strobed actions.
    mos6502_registers u_regs (
        .clk              (clk),
        .reset_n          (reset_n),
        .ready            (ready_advance),
        .nmi_n            (nmi_n),
        .so_n             (so_n),
        .irq_n            (irq_n),
        .state_d          (state_d),
        .data_in          (data_in),
        .address_live     (address_d),
        .am               (am),
        .opk              (opk),
        .alu_op           (alu_op),
        .alu_result       (alu_result),
        .alu_co           (alu_co),
        .combo_result     (combo_result),
        .combo_co         (combo_co),
        .combo_ov         (combo_ov),
        .combo_writes_a   (combo_writes_a),
        .is_combined_rmw  (is_combined_rmw),
        .idx_value        (idx_value),
        .adlo_plus_idx    (adlo_plus_idx),
        .load_commit      (load_commit),
        .load_target      (load_target),
        .alu_commit_a     (alu_commit_a),
        .alu_commit_acc   (alu_commit_acc),
        .alu_commit_xy    (alu_commit_xy),
        .alu_commit_imm_a (alu_commit_imm_a),
        .alu_commit_imm_x (alu_commit_imm_x),
        .imm_combo_result (imm_combo_result),
        .rmw_latch        (rmw_latch),
        .xfer_active      (xfer_active),
        .xfer_value       (xfer_value),
        .xfer_dst         (xfer_dst),
        .xfer_upd_nz      (xfer_upd_nz),
        .flag_active      (flag_active),
        .flag_update_nz   (flag_update_nz),
        .flag_update_c    (flag_update_c),
        .flag_update_v    (flag_update_v),
        .nz_value         (nz_value),
        .v_value          (v_value),
        .c_value          (c_value),
        .use_overrides    (use_overrides),
        .n_override       (n_override),
        .v_override       (v_override),
        .las_commit       (las_commit),
        .las_value        (las_value),
        .tas_s_commit     (tas_s_commit),
        .a_q              (a_q),
        .x_q              (x_q),
        .y_q              (y_q),
        .s_q              (s_q),
        .p_q              (p_q),
        .ir_q             (ir_q),
        .pc_q             (pc_q),
        .ad_lo_q          (ad_lo_q),
        .ad_hi_q          (ad_hi_q),
        .ptr_q            (ptr_q),
        .idx_carry_q      (idx_carry_q),
        .alu_in_q         (alu_in_q),
        .rmw_target_q     (rmw_target_q),
        .branch_offset_q  (branch_offset_q),
        .branch_cross_q   (branch_cross_q),
        .branch_neg_q     (branch_neg_q),
        .int_mode_q       (int_mode_q),
        .nmi_pending_q    (nmi_pending_q),
        .state_q          (state_q)
    );

    // ------------------------------------------------------------------------
    // Tie-offs for currently-unread internal signals.
    // ------------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    // branch_offset_q and branch_neg_q are produced by mos6502_registers and
    // consumed only inside that module (the FF logic that latches the branch
    // staging). They surface here as outputs of u_regs but are unused by the
    // control combinational. Same for alu_ov / opk_next / unused P bits.
    wire _unused = &{1'b0, alu_zr, alu_ne, alu_ov, opk_next,
                     combo_zr, combo_ne, p_q[5:4],
                     branch_offset_q, branch_neg_q};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
