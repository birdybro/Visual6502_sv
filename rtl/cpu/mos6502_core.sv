// SPDX-License-Identifier: MIT
//
// mos6502_core — synthesizable 6502 CPU.
//
// Single-edge synchronous: one `clk` rising edge advances the bus by exactly
// one cycle. AB / RW / SYNC / data_out are combinational from the current FSM
// state and register file; architectural state updates at the rising edge.
//
// Coverage:
//   M3: reset, opcode fetch, NOP, unknown opcodes as 2-cycle path.
//   M4: LDA/LDX/LDY, STA/STX/STY across IMM/ZP/ZPX/ZPY/ABS/ABSX/ABSY/INDX/INDY.
//       TAX/TAY/TXA/TYA/TSX/TXS. N/Z flags. Indexed page-cross dummy cycle.
//   M5: ALU ops (ADC, SBC, AND, ORA, EOR, CMP, CPX, CPY, BIT) across the
//       same modes. Decimal-mode ADC/SBC (NMOS). RMW (ASL/LSR/ROL/ROR/INC/DEC)
//       on memory (read-dummy-write-write sequence) and on accumulator/
//       register (implied 2-cycle). INX/INY/DEX/DEY. CLC/SEC/CLI/SEI/CLD/
//       SED/CLV.

`default_nettype none

module mos6502_core
    import mos6502_decode_pkg::*;
    import mos6502_alu_pkg::*;
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
    // State enumeration.
    // ------------------------------------------------------------------------
    typedef enum logic [6:0] {
        S_RESET_0, S_RESET_1, S_RESET_2, S_RESET_3, S_RESET_4, S_RESET_5,
        S_FETCH,
        S_T1_DUMMY,
        S_IMM_RW,
        S_ZP_ADDR,    S_ZP_RW,
        S_ZPI_ADDR,   S_ZPI_DUMMY,  S_ZPI_RW,
        S_ABS_LO,     S_ABS_HI,     S_ABS_RW,
        S_ABSI_LO,    S_ABSI_HI,    S_ABSI_DUMMY, S_ABSI_RW,
        S_INDX_ZP,    S_INDX_DUMMY, S_INDX_LO,    S_INDX_HI,   S_INDX_RW,
        S_INDY_ZP,    S_INDY_LO,    S_INDY_HI,    S_INDY_DUMMY, S_INDY_RW,
        // RMW tail.
        S_RMW_DUMMY_WRITE, S_RMW_WRITE,
        // Stack (PHA/PHP/PLA/PLP).
        S_PUSH_T1,    S_PUSH_T2,
        S_PULL_T1,    S_PULL_T2,    S_PULL_T3,
        // JSR.
        S_JSR_LO,     S_JSR_PEEK,   S_JSR_PUSH_PCH, S_JSR_PUSH_PCL, S_JSR_HI,
        // RTS.
        S_RTS_T1,     S_RTS_PEEK,   S_RTS_PULL_PCL, S_RTS_PULL_PCH, S_RTS_INC,
        // RTI.
        S_RTI_T1,     S_RTI_PEEK,   S_RTI_PULL_P,   S_RTI_PULL_PCL, S_RTI_PULL_PCH,
        // BRK / IRQ / NMI entry. BRK reaches S_INT_T1 from FETCH;
        // IRQ/NMI go through S_INT_T0 first.
        S_INT_T0,     S_INT_T1,
        S_INT_PUSH_PCH, S_INT_PUSH_PCL, S_INT_PUSH_P,
        S_INT_VEC_LO, S_INT_VEC_HI,
        // Conditional branches.
        S_BR_OFFSET,       // T1: fetch offset, evaluate predicate
        S_BR_TAKEN,        // T2 (taken): dummy at unfixed PC; check page cross
        S_BR_FIXUP,        // T3 (taken+cross): dummy at fixed PC
        // JMP absolute and JMP indirect.
        S_JMP_ABS_LO, S_JMP_ABS_HI,
        S_JMP_IND_LO, S_JMP_IND_HI, S_JMP_IND_PCL, S_JMP_IND_PCH,
        S_HALT
    } state_e;

    state_e state_q;

    // ------------------------------------------------------------------------
    // Architectural / staging registers.
    // ------------------------------------------------------------------------
    logic [7:0]  a_q, x_q, y_q, s_q, p_q, ir_q;
    logic [15:0] pc_q;
    logic [7:0]  ad_lo_q, ad_hi_q, ptr_q;
    logic        idx_carry_q;
    logic [7:0]  alu_in_q;
    logic [15:0] rmw_target_q;
    // Branch staging.
    logic [7:0]  branch_offset_q;
    logic        branch_cross_q;
    logic        branch_neg_q;
    // Interrupt entry mode and pending latches. The testbench drives clean
    // synchronous inputs in our environment so we sample nmi_n / irq_n
    // directly (no synchronizer chain). If integrating with a real async
    // pin source, add a synchronizer at the boundary.
    typedef enum logic [1:0] { INT_BRK, INT_IRQ, INT_NMI, INT_RESET } int_mode_e;
    int_mode_e   int_mode_q;
    logic        nmi_n_prev_q;
    logic        nmi_pending_q;
    logic        so_n_prev_q;

    // RDY freeze: writes complete even when ready==0, but read cycles
    // are paused. This matches the documented 6502 RDY semantics.
    logic ready_advance;
    assign ready_advance = ready || !rw;

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

    // is_rmw_mem: an RMW that uses a memory operand (not accumulator/implied).
    logic is_rmw_mem;
    assign is_rmw_mem = (opk == OP_RMW) && (am != AM_ACC) && (am != AM_IMPL);
    logic is_store;
    assign is_store = (opk == OP_STORE);
    // For the indexed dummy-skip optimization: skip the dummy if we are
    // doing a load (no store, no RMW) and no page cross.
    logic indexed_dummy_skippable;
    assign indexed_dummy_skippable = !is_store && !is_rmw_mem && !idx_carry_q;

    // Target register for LD?/ST? from IR bits [1:0]. 00=Y, 01=A, 10=X.
    // IR[1:0]==11 is the undocumented SAX/LAX family: store_src = A AND X,
    // load_target writes both A and X.
    logic [7:0] store_src;
    always_comb begin
        unique case (ir_q[1:0])
            2'b00:   store_src = y_q;
            2'b01:   store_src = a_q;
            2'b10:   store_src = x_q;
            2'b11:   store_src = a_q & x_q;   // SAX
            default: store_src = 8'h00;
        endcase
    end
    logic [2:0] load_target;
    always_comb begin
        unique case (ir_q[1:0])
            2'b00:   load_target = 3'b010; // Y
            2'b01:   load_target = 3'b000; // A
            2'b10:   load_target = 3'b001; // X
            2'b11:   load_target = 3'b011; // LAX (both A and X)
            default: load_target = 3'b000;
        endcase
    end

    // Index value (X or Y) for indexed modes.
    logic [7:0] idx_value;
    always_comb begin
        unique case (am)
            AM_ZPX, AM_ABSX, AM_INDX: idx_value = x_q;
            AM_ZPY, AM_ABSY, AM_INDY: idx_value = y_q;
            default:                  idx_value = 8'h00;
        endcase
    end

    // ------------------------------------------------------------------------
    // ALU operand selection.
    // ------------------------------------------------------------------------
    alu_op_e    alu_op;
    logic [7:0] alu_a;
    logic [7:0] alu_b;
    logic [7:0] alu_result;
    logic       alu_co, alu_ov, alu_zr, alu_ne;

    // Map IR → ALU op.
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
            8'h0A, 8'h06, 8'h16, 8'h0E, 8'h1E:                       ir_to_alu_op = ALU_ASL;
            8'h2A, 8'h26, 8'h36, 8'h2E, 8'h3E:                       ir_to_alu_op = ALU_ROL;
            8'h4A, 8'h46, 8'h56, 8'h4E, 8'h5E:                       ir_to_alu_op = ALU_LSR;
            8'h6A, 8'h66, 8'h76, 8'h6E, 8'h7E:                       ir_to_alu_op = ALU_ROR;
            8'hE6, 8'hF6, 8'hEE, 8'hFE, 8'hE8, 8'hC8:                ir_to_alu_op = ALU_INC;
            8'hC6, 8'hD6, 8'hCE, 8'hDE, 8'hCA, 8'h88:                ir_to_alu_op = ALU_DEC;
            default:                                                  ir_to_alu_op = ALU_NONE;
        endcase
    endfunction

    // ALU `a` source. For CPX/CPY pull X/Y. For INX/DEX/INY/DEY pull X/Y.
    // For shifts on accumulator pull A. For memory RMW second/third cycle
    // pull the staged alu_in_q. Default to A.
    logic [7:0] alu_a_sel;
    always_comb begin
        // RMW staging: when computing the new value for memory, use alu_in_q.
        if ((state_q == S_RMW_DUMMY_WRITE) || (state_q == S_RMW_WRITE)) begin
            alu_a_sel = alu_in_q;
        end else if ((state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_IMPL)) begin
            // INX / INY / DEX / DEY.
            unique case (ir_q)
                8'hE8, 8'hCA: alu_a_sel = x_q;
                8'hC8, 8'h88: alu_a_sel = y_q;
                default:      alu_a_sel = 8'h00;
            endcase
        end else if ((state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_ACC)) begin
            alu_a_sel = a_q;
        end else begin
            // ALU op on memory operand: CPX uses X, CPY uses Y, others use A.
            unique case (ir_q)
                8'hE0, 8'hE4, 8'hEC: alu_a_sel = x_q; // CPX
                8'hC0, 8'hC4, 8'hCC: alu_a_sel = y_q; // CPY
                default:              alu_a_sel = a_q;
            endcase
        end
    end

    assign alu_op = ir_to_alu_op(ir_q);
    assign alu_a  = alu_a_sel;
    assign alu_b  = data_in;   // for ALU-on-memory cycles. Don't-care otherwise.

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

    // ------------------------------------------------------------------------
    // Bus output and next state — combinational.
    // ------------------------------------------------------------------------
    logic [15:0] address_d;
    logic [7:0]  data_out_d;
    logic        rw_d;
    logic        sync_d;
    state_e      state_d;

    logic [8:0]  adlo_plus_idx;
    assign adlo_plus_idx = {1'b0, ad_lo_q} + {1'b0, idx_value};

    // Helper: choose what to put on data_out during a write.
    // - For OP_STORE: store_src
    // - For OP_RMW dummy write: alu_in_q (the value just read)
    // - For OP_RMW final write: alu_result
    // Memory address comes from {ad_hi, ad_lo} for all RMW write cycles.

    function automatic state_e first_state_for(input addr_mode_e m,
                                               input op_kind_e   o);
        // Op-kind-specific dispatch overrides addressing-mode dispatch for
        // the "special" instructions whose cycle layout does not follow the
        // generic addr-mode template.
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

    // After a *_RW state, where do we go?
    state_e rw_next;
    always_comb begin
        rw_next = is_rmw_mem ? S_RMW_DUMMY_WRITE : S_FETCH;
    end

    // Branch predicate. ir[7:6] selects flag (00=N,01=V,10=C,11=Z), ir[5]
    // is the polarity (1 = branch when flag set, 0 = branch when clear).
    function automatic logic branch_taken_now();
        logic flag_val;
        unique case (ir_q[7:6])
            2'b00:   flag_val = p_q[7]; // N
            2'b01:   flag_val = p_q[6]; // V
            2'b10:   flag_val = p_q[0]; // C
            2'b11:   flag_val = p_q[1]; // Z
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
                // If an interrupt is pending (NMI edge or unmasked IRQ), the
                // fetched byte is discarded and we enter the interrupt
                // sequence instead. sync still asserts (the bus cycle is
                // identical from the outside) — actually the 6502 suppresses
                // SYNC during forced-BRK; emulate that. The first integration
                // pass keeps SYNC high so it doesn't affect bus equivalence.
                if (nmi_pending_q || (!irq_n && !p_q[2])) begin
                    sync_d  = 1'b0;
                    state_d = S_INT_T0;
                end else begin
                    sync_d  = 1'b1;
                    state_d = first_state_for(am_next, opk_next);
                end
            end

            S_T1_DUMMY: begin
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            S_IMM_RW: begin
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            S_ZP_ADDR:  begin address_d = pc_q;             state_d = S_ZP_RW;     end
            S_ZP_RW: begin
                address_d  = {8'h00, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_ZPI_ADDR:  begin address_d = pc_q;            state_d = S_ZPI_DUMMY; end
            S_ZPI_DUMMY: begin address_d = {8'h00, ad_lo_q};state_d = S_ZPI_RW;    end
            S_ZPI_RW: begin
                address_d  = {8'h00, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_ABS_LO: begin address_d = pc_q;               state_d = S_ABS_HI;    end
            S_ABS_HI: begin address_d = pc_q;               state_d = S_ABS_RW;    end
            S_ABS_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = rw_next;
            end

            S_ABSI_LO:  begin address_d = pc_q;             state_d = S_ABSI_HI;   end
            S_ABSI_HI:  begin address_d = pc_q;             state_d = S_ABSI_DUMMY;end
            S_ABSI_DUMMY: begin
                address_d = {ad_hi_q, ad_lo_q};
                if (indexed_dummy_skippable) begin
                    // Skip dummy: this cycle is the real load.
                    rw_d    = 1'b1;
                    state_d = rw_next;   // == S_FETCH (RMW never reaches here w/ skippable)
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

            // ---- RMW tail ----
            S_RMW_DUMMY_WRITE: begin
                address_d  = rmw_target_q;
                rw_d       = 1'b0;
                data_out_d = alu_in_q;
                state_d    = S_RMW_WRITE;
            end
            S_RMW_WRITE: begin
                address_d  = rmw_target_q;
                rw_d       = 1'b0;
                data_out_d = alu_result;
                state_d    = S_FETCH;
            end

            // ---- Stack push (PHA/PHP) ----
            S_PUSH_T1: begin
                address_d = pc_q;
                state_d   = S_PUSH_T2;
            end
            S_PUSH_T2: begin
                address_d  = {8'h01, s_q};
                rw_d       = 1'b0;
                // PHA pushes A; PHP pushes P with bits 4 and 5 set.
                data_out_d = (ir_q == 8'h08) ? (p_q | 8'h30) : a_q;
                state_d    = S_FETCH;
            end

            // ---- Stack pull (PLA/PLP) ----
            S_PULL_T1: begin
                address_d = pc_q;
                state_d   = S_PULL_T2;
            end
            S_PULL_T2: begin
                address_d = {8'h01, s_q};
                state_d   = S_PULL_T3;
            end
            S_PULL_T3: begin
                address_d = {8'h01, s_q + 8'h01};
                state_d   = S_FETCH;
            end

            // ---- JSR ----
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
            S_JSR_HI: begin
                // Fetch the high byte of the target. PC is still at the
                // address of that byte (incremented past the low byte during
                // S_JSR_LO's PC++).
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            // ---- RTS ----
            S_RTS_T1:         begin address_d = pc_q;                state_d = S_RTS_PEEK;     end
            S_RTS_PEEK:       begin address_d = {8'h01, s_q};        state_d = S_RTS_PULL_PCL; end
            S_RTS_PULL_PCL:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTS_PULL_PCH; end
            S_RTS_PULL_PCH:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTS_INC;     end
            S_RTS_INC:        begin address_d = pc_q;                state_d = S_FETCH;        end

            // ---- RTI ----
            S_RTI_T1:         begin address_d = pc_q;                state_d = S_RTI_PEEK;    end
            S_RTI_PEEK:       begin address_d = {8'h01, s_q};        state_d = S_RTI_PULL_P;  end
            S_RTI_PULL_P:     begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTI_PULL_PCL;end
            S_RTI_PULL_PCL:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_RTI_PULL_PCH;end
            S_RTI_PULL_PCH:   begin address_d = {8'h01, s_q + 8'h01}; state_d = S_FETCH;       end

            // ---- BRK / IRQ / NMI entry ----
            // BRK enters at S_INT_T1 (T0 was the opcode fetch itself).
            // IRQ/NMI enter at S_INT_T0 (the "discarded fetch" cycle).
            S_INT_T0: begin
                address_d = pc_q;
                state_d   = S_INT_T1;
            end
            S_INT_T1: begin
                address_d = pc_q;
                state_d   = S_INT_PUSH_PCH;
            end
            S_INT_PUSH_PCH: begin
                address_d  = {8'h01, s_q};
                // For an IRQ/NMI in normal operation the suppress-write
                // behavior of the reset sequence does NOT apply. Always write.
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
                // BRK: push P with B=1, unused=1. IRQ/NMI: B=0, unused=1.
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

            // ---- Conditional branches ----
            S_BR_OFFSET: begin
                address_d = pc_q;
                // Decide next state based on predicate (combinational on
                // current p_q and ir_q[7:5]).
                if (branch_taken_now()) begin
                    state_d = S_BR_TAKEN;
                end else begin
                    state_d = S_FETCH;
                end
            end
            S_BR_TAKEN: begin
                // pc_q already advanced past the offset byte; we set PC's
                // low byte to PC_lo + offset in the ff block on entry to this
                // state. AB shows the unfixed-up PC. If no page cross we go
                // straight to FETCH; otherwise to S_BR_FIXUP.
                address_d = pc_q;
                if (branch_cross_q) state_d = S_BR_FIXUP;
                else                state_d = S_FETCH;
            end
            S_BR_FIXUP: begin
                // AB shows the fixed PC (high byte adjusted). Dummy read,
                // then fetch.
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            // ---- JMP absolute / indirect ----
            S_JMP_ABS_LO: begin
                address_d = pc_q;
                state_d   = S_JMP_ABS_HI;
            end
            S_JMP_ABS_HI: begin
                address_d = pc_q;
                state_d   = S_FETCH;
            end
            S_JMP_IND_LO: begin
                address_d = pc_q;
                state_d   = S_JMP_IND_HI;
            end
            S_JMP_IND_HI: begin
                address_d = pc_q;
                state_d   = S_JMP_IND_PCL;
            end
            S_JMP_IND_PCL: begin
                address_d = {ad_hi_q, ad_lo_q};
                state_d   = S_JMP_IND_PCH;
            end
            S_JMP_IND_PCH: begin
                // 6502 indirect-jmp wrap bug: only the low byte of the
                // pointer is incremented for the PCH fetch.
                address_d = {ad_hi_q, ad_lo_q + 8'h01};
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

    // ------------------------------------------------------------------------
    // Commit and flag-update logic.
    // ------------------------------------------------------------------------
    // Helper: identify the "RW cycle" (read from memory or write store_src)
    // for the current addressing mode. This is the state where load_commit /
    // alu_commit / rmw_in_latch happens.
    logic in_rw_state;
    always_comb begin
        in_rw_state = (state_q == S_IMM_RW)
                    | (state_q == S_ZP_RW)
                    | (state_q == S_ZPI_RW)
                    | (state_q == S_ABS_RW)
                    | (state_q == S_ABSI_RW)
                    | (state_q == S_INDX_RW)
                    | (state_q == S_INDY_RW)
                    // Collapsed reads (indexed loads, no page cross).
                    | ((state_q == S_ABSI_DUMMY) && indexed_dummy_skippable)
                    | ((state_q == S_INDY_DUMMY) && indexed_dummy_skippable);
    end

    logic load_commit;       // commit a load (LDA/LDX/LDY)
    logic alu_commit_a;      // commit ALU result to A (ORA/AND/EOR/ADC/SBC)
    logic alu_commit_xy;     // commit ALU result for INX/INY/DEX/DEY (am=IMPL)
    logic alu_commit_acc;    // commit ALU result to A for ASL A / LSR A / etc.
    logic rmw_latch;         // latch data_in into alu_in_q at this *_RW cycle
    logic flag_update_nz;    // update N/Z
    logic flag_update_c;     // update C
    logic flag_update_v;     // update V

    // Flag value sources.
    logic [7:0] nz_value;    // value whose [7]/==0 drive N/Z
    logic       v_value;
    logic       c_value;
    logic       n_override;  // for BIT, N comes from data_in[7]
    logic       v_override;  // for BIT, V comes from data_in[6]
    logic       use_overrides;

    // ALU vs non-ALU at *_RW for an OP_ALU opcode. For OP_LOAD it's just a
    // load. For OP_STORE it's a store. For OP_RMW it's a memory-RMW read.
    logic is_alu_compute_cycle;
    assign is_alu_compute_cycle = in_rw_state && (opk == OP_ALU);
    logic is_rmw_read_cycle;
    assign is_rmw_read_cycle    = in_rw_state && is_rmw_mem;
    logic is_load_cycle;
    assign is_load_cycle        = in_rw_state && (opk == OP_LOAD);

    // Transfer instruction handling at S_T1_DUMMY.
    logic        xfer_active;
    logic [7:0]  xfer_value;
    logic [1:0]  xfer_dst;
    logic        xfer_upd_nz;
    always_comb begin
        xfer_active = (state_q == S_T1_DUMMY) && (opk == OP_XFER);
        unique case (ir_q)
            8'hAA: begin xfer_value = a_q; xfer_dst = 2'b01; xfer_upd_nz = 1'b1; end // TAX
            8'hA8: begin xfer_value = a_q; xfer_dst = 2'b10; xfer_upd_nz = 1'b1; end // TAY
            8'h8A: begin xfer_value = x_q; xfer_dst = 2'b00; xfer_upd_nz = 1'b1; end // TXA
            8'h98: begin xfer_value = y_q; xfer_dst = 2'b00; xfer_upd_nz = 1'b1; end // TYA
            8'hBA: begin xfer_value = s_q; xfer_dst = 2'b01; xfer_upd_nz = 1'b1; end // TSX
            8'h9A: begin xfer_value = x_q; xfer_dst = 2'b11; xfer_upd_nz = 1'b0; end // TXS
            default: begin xfer_value = 8'h00; xfer_dst = 2'b00; xfer_upd_nz = 1'b0; end
        endcase
    end

    // Implied RMW (INX/INY/DEX/DEY) and accumulator RMW (ASL A / LSR A / etc.).
    logic        implied_rmw_active;
    logic        acc_rmw_active;
    always_comb begin
        implied_rmw_active = (state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_IMPL);
        acc_rmw_active     = (state_q == S_T1_DUMMY) && (opk == OP_RMW) && (am == AM_ACC);
    end

    // Flag set/clear.
    logic flag_active;
    assign flag_active = (state_q == S_T1_DUMMY) && (opk == OP_FLAG);

    always_comb begin
        load_commit     = 1'b0;
        alu_commit_a    = 1'b0;
        alu_commit_xy   = 1'b0;
        alu_commit_acc  = 1'b0;
        rmw_latch       = 1'b0;
        flag_update_nz  = 1'b0;
        flag_update_c   = 1'b0;
        flag_update_v   = 1'b0;
        nz_value        = 8'h00;
        v_value         = 1'b0;
        c_value         = 1'b0;
        n_override      = 1'b0;
        v_override      = 1'b0;
        use_overrides   = 1'b0;

        if (is_load_cycle) begin
            load_commit    = 1'b1;
            flag_update_nz = 1'b1;
            nz_value       = data_in;
        end else if (is_rmw_read_cycle) begin
            // Latch the operand byte; flags update at S_RMW_WRITE.
            rmw_latch = 1'b1;
        end else if (is_alu_compute_cycle) begin
            // ALU op on memory operand.
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
                    nz_value        = alu_result;     // Z from a&b
                    v_value         = data_in[6];
                    n_override      = 1'b1;
                    use_overrides   = 1'b1;
                end
                default: ;
            endcase
        end else if (state_q == S_RMW_WRITE) begin
            // Memory RMW final write: also update flags from the ALU result.
            flag_update_nz = 1'b1;
            nz_value       = alu_result;
            unique case (alu_op)
                ALU_ASL, ALU_LSR, ALU_ROL, ALU_ROR: begin
                    flag_update_c = 1'b1;
                    c_value       = alu_co;
                end
                default: ;  // INC/DEC: only N/Z
            endcase
        end else if (acc_rmw_active) begin
            // ASL A / LSR A / ROL A / ROR A: write back to A.
            alu_commit_acc = 1'b1;
            flag_update_nz = 1'b1;
            nz_value       = alu_result;
            flag_update_c  = 1'b1;
            c_value        = alu_co;
        end else if (implied_rmw_active) begin
            // INX / INY / DEX / DEY.
            alu_commit_xy  = 1'b1;
            flag_update_nz = 1'b1;
            nz_value       = alu_result;
        end
    end

    // ------------------------------------------------------------------------
    // Synchronous updates.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state_q        <= S_RESET_0;
            a_q            <= 8'h00;
            x_q            <= 8'h00;
            y_q            <= 8'h00;
            s_q            <= 8'h00;
            p_q            <= 8'h24;
            ir_q           <= 8'h00;
            pc_q           <= 16'h0000;
            ad_lo_q        <= 8'h00;
            ad_hi_q        <= 8'h00;
            ptr_q          <= 8'h00;
            idx_carry_q    <= 1'b0;
            alu_in_q       <= 8'h00;
            rmw_target_q   <= 16'h0000;
            branch_offset_q<= 8'h00;
            branch_cross_q <= 1'b0;
            branch_neg_q   <= 1'b0;
            int_mode_q     <= INT_RESET;
            nmi_n_prev_q   <= 1'b1;
            nmi_pending_q  <= 1'b0;
            so_n_prev_q    <= 1'b1;
        end else if (ready_advance) begin
            // NMI edge detection on raw nmi_n. Latched on the falling edge.
            nmi_n_prev_q <= nmi_n;
            if (nmi_n_prev_q && !nmi_n) begin
                nmi_pending_q <= 1'b1;
            end

            // SO falling-edge → set V flag. Sampled on the same clk so
            // a one-cycle low pulse suffices.
            so_n_prev_q <= so_n;
            if (so_n_prev_q && !so_n) begin
                p_q[6] <= 1'b1;
            end

            state_q <= state_d;

            unique case (state_q)
                S_RESET_1, S_RESET_2, S_RESET_3: s_q <= s_q - 8'h01;
                S_RESET_4: pc_q[7:0]  <= data_in;
                S_RESET_5: pc_q[15:8] <= data_in;
                default: ;
            endcase

            unique case (state_q)
                S_FETCH: begin
                    // If an interrupt is pending, the fetched byte is
                    // discarded — don't latch IR, don't advance PC. Otherwise
                    // it's a normal fetch.
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
                S_IMM_RW: begin
                    pc_q <= pc_q + 16'd1;
                end
                // Stack push: decrement S at the cycle the write goes out.
                S_PUSH_T2: begin
                    s_q <= s_q - 8'h01;
                end
                // Stack pull: increment S at the cycle the pulled data is
                // latched (S_PULL_T3). The actual load into A or P is in
                // the dedicated commit blocks below.
                S_PULL_T3: begin
                    s_q <= s_q + 8'h01;
                end
                // JSR
                S_JSR_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JSR_PUSH_PCH, S_JSR_PUSH_PCL: begin
                    s_q <= s_q - 8'h01;
                end
                S_JSR_HI: begin
                    // PC <= {high_byte_fetched, ad_lo_q}. The fetch sets PC
                    // for the very next S_FETCH; don't increment PC further.
                    pc_q <= {data_in, ad_lo_q};
                end
                // RTS
                S_RTS_PULL_PCL: begin
                    pc_q[7:0] <= data_in;
                    s_q       <= s_q + 8'h01;
                end
                S_RTS_PULL_PCH: begin
                    pc_q[15:8] <= data_in;
                    s_q        <= s_q + 8'h01;
                end
                S_RTS_INC: begin
                    pc_q <= pc_q + 16'd1;
                end
                // RTI
                S_RTI_PULL_P: begin
                    // Pull P. NMOS quirk: bit 4 of pulled byte is discarded
                    // (always reads as 0 in storage), bit 5 always 1.
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
                // Branches: T1 fetches the offset and advances PC past it.
                // Also latches whether the offset is negative and whether
                // the upcoming PCL+offset add will cross a page.
                S_BR_OFFSET: begin
                    branch_offset_q <= data_in;
                    branch_neg_q    <= data_in[7];
                    // Detect page cross relative to the post-fetch PC
                    // (which is pc_q+1 at this point).
                    if (data_in[7]) begin
                        // Negative offset: borrow if PCL_after < |offset|
                        branch_cross_q <= ((pc_q[7:0] + 8'h01) < (~data_in + 8'h01));
                    end else begin
                        // Positive offset: carry if PCL_after + offset > 255
                        branch_cross_q <= (({1'b0, pc_q[7:0] + 8'h01} +
                                            {1'b0, data_in}) > 9'h0FF);
                    end
                    pc_q            <= pc_q + 16'd1;
                end
                // S_BR_TAKEN: PC was incremented to "PC after branch instr"
                // in S_BR_OFFSET. We now apply the offset to PCL only and
                // remember whether the high byte needs fixing.
                S_BR_TAKEN: begin
                    pc_q[7:0]      <= pc_q[7:0] + branch_offset_q;
                end
                // S_BR_FIXUP: apply the high-byte correction.
                S_BR_FIXUP: begin
                    if (branch_neg_q) pc_q[15:8] <= pc_q[15:8] - 8'h01;
                    else              pc_q[15:8] <= pc_q[15:8] + 8'h01;
                end

                // JMP absolute / indirect: latch lo, hi, and update PC.
                S_JMP_ABS_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JMP_ABS_HI: begin
                    pc_q <= {data_in, ad_lo_q};
                end
                S_JMP_IND_LO: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JMP_IND_HI: begin
                    ad_hi_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_JMP_IND_PCL: begin
                    pc_q[7:0] <= data_in;
                end
                S_JMP_IND_PCH: begin
                    pc_q[15:8] <= data_in;
                end

                // INT entry
                S_INT_T1: begin
                    // For BRK only, advance past the signature byte.
                    if (int_mode_q == INT_BRK) pc_q <= pc_q + 16'd1;
                end
                S_INT_PUSH_PCH, S_INT_PUSH_PCL: begin
                    s_q <= s_q - 8'h01;
                end
                S_INT_PUSH_P: begin
                    s_q    <= s_q - 8'h01;
                    p_q[2] <= 1'b1;       // set I flag during interrupt entry
                end
                S_INT_VEC_LO: begin
                    pc_q[7:0] <= data_in;
                end
                S_INT_VEC_HI: begin
                    pc_q[15:8] <= data_in;
                    if (int_mode_q == INT_NMI) nmi_pending_q <= 1'b0;
                end
                S_ZP_ADDR, S_ZPI_ADDR: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_ZPI_DUMMY: begin
                    ad_lo_q <= ad_lo_q + idx_value;
                end
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
                S_ABSI_DUMMY: begin
                    if (idx_carry_q) ad_hi_q <= ad_hi_q + 8'h01;
                end
                S_INDX_DUMMY: begin
                    ptr_q <= ptr_q + x_q;
                end
                S_INDX_LO: ad_lo_q <= data_in;
                S_INDX_HI: ad_hi_q <= data_in;
                S_INDY_LO: ad_lo_q <= data_in;
                S_INDY_HI: begin
                    ad_hi_q     <= data_in;
                    ad_lo_q     <= adlo_plus_idx[7:0];
                    idx_carry_q <= adlo_plus_idx[8];
                end
                S_INDY_DUMMY: begin
                    if (idx_carry_q) ad_hi_q <= ad_hi_q + 8'h01;
                end
                default: ;
            endcase

            // Capture RMW target address at the read cycle (so RMW writes hit
            // the same address even though ad_hi/ad_lo logic might have
            // already changed by the time we get to *_WRITE).
            if (rmw_latch) begin
                alu_in_q     <= data_in;
                rmw_target_q <= {ad_hi_q, ad_lo_q};
            end

            // Load commit (LDA/LDX/LDY/LAX). load_target: 000=A, 001=X,
            // 010=Y, 011=both A and X (LAX).
            if (load_commit) begin
                unique case (load_target)
                    3'b000: a_q <= data_in;
                    3'b001: x_q <= data_in;
                    3'b010: y_q <= data_in;
                    3'b011: begin a_q <= data_in; x_q <= data_in; end
                    default: ;
                endcase
            end

            // ALU commit to A.
            if (alu_commit_a || alu_commit_acc) begin
                a_q <= alu_result;
            end

            // PLA / PLP commit (at S_PULL_T3, the cycle when DB has the
            // pulled byte). PLA = $68, PLP = $28.
            if (state_q == S_PULL_T3) begin
                if (ir_q == 8'h68) begin
                    a_q    <= data_in;
                    p_q[1] <= (data_in == 8'h00);
                    p_q[7] <= data_in[7];
                end else if (ir_q == 8'h28) begin
                    // PLP: discard bit 4 (B), force bit 5 (unused) to 1.
                    p_q <= (data_in & 8'hEF) | 8'h20;
                end
            end

            // ALU commit to X/Y for INX/INY/DEX/DEY.
            if (alu_commit_xy) begin
                unique case (ir_q)
                    8'hE8, 8'hCA: x_q <= alu_result; // INX, DEX
                    8'hC8, 8'h88: y_q <= alu_result; // INY, DEY
                    default: ;
                endcase
            end

            // Transfer commit.
            if (xfer_active) begin
                unique case (xfer_dst)
                    2'b00: a_q <= xfer_value;
                    2'b01: x_q <= xfer_value;
                    2'b10: y_q <= xfer_value;
                    2'b11: s_q <= xfer_value;
                endcase
            end

            // Flag set/clear.
            if (flag_active) begin
                unique case (ir_q)
                    8'h18: p_q[0] <= 1'b0;   // CLC
                    8'h38: p_q[0] <= 1'b1;   // SEC
                    8'h58: p_q[2] <= 1'b0;   // CLI
                    8'h78: p_q[2] <= 1'b1;   // SEI
                    8'hD8: p_q[3] <= 1'b0;   // CLD
                    8'hF8: p_q[3] <= 1'b1;   // SED
                    8'hB8: p_q[6] <= 1'b0;   // CLV
                    default: ;
                endcase
            end

            // Flag updates.
            if (flag_update_nz) begin
                p_q[1] <= (nz_value == 8'h00);
                p_q[7] <= use_overrides && n_override ? data_in[7] : nz_value[7];
            end
            if (flag_update_c) begin
                p_q[0] <= c_value;
            end
            if (flag_update_v) begin
                p_q[6] <= use_overrides && v_override ? data_in[6] : v_value;
            end

            // Transfer flag update.
            if (xfer_active && xfer_upd_nz) begin
                p_q[1] <= (xfer_value == 8'h00);
                p_q[7] <= xfer_value[7];
            end
        end
    end

    // ------------------------------------------------------------------------
    // Tie-offs.
    // ------------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    wire _unused = &{1'b0, alu_zr, alu_ne, opk_next, p_q[7:4], p_q[2:1]};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
