// SPDX-License-Identifier: MIT
//
// mos6502_core — synthesizable 6502 CPU.
//
// Single-edge synchronous: one `clk` rising edge advances the bus by exactly
// one cycle. AB / RW / SYNC / data_out are combinational from the current FSM
// state and register file; architectural state updates at the rising edge.
//
// Coverage:
//   M3: reset, opcode fetch, NOP, default 2-cycle path for unknown opcodes.
//   M4: LDA/LDX/LDY, STA/STX/STY across IMM/ZP/ZPX/ZPY/ABS/ABSX/ABSY/INDX/INDY.
//       TAX/TAY/TXA/TYA/TSX/TXS transfers. N/Z flags on loads/transfers.
//       Page-crossing dummy cycle: skipped on loads with no cross, always
//       taken on stores.
//
// Later milestones extend op_kind handling at the *_RW states; addressing-
// mode plumbing already produces the right AB/cycle count, so adding ALU ops,
// RMW, branches, JSR/RTS/BRK/RTI, JMP, and stack instructions slots in here.

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

    // ------------------------------------------------------------------------
    // State enumeration. New states get appended in later milestones.
    // ------------------------------------------------------------------------
    typedef enum logic [5:0] {
        // Reset
        S_RESET_0,
        S_RESET_1,
        S_RESET_2,
        S_RESET_3,
        S_RESET_4,
        S_RESET_5,
        // Fetch
        S_FETCH,
        // 2-cycle implied
        S_T1_DUMMY,
        // Immediate operand (2-cycle loads, also ALU/CMP imm later)
        S_IMM_RW,
        // Zero-page direct
        S_ZP_ADDR,
        S_ZP_RW,
        // Zero-page indexed (ZP,X / ZP,Y)
        S_ZPI_ADDR,
        S_ZPI_DUMMY,
        S_ZPI_RW,
        // Absolute direct
        S_ABS_LO,
        S_ABS_HI,
        S_ABS_RW,
        // Absolute indexed
        S_ABSI_LO,
        S_ABSI_HI,
        S_ABSI_DUMMY,
        S_ABSI_RW,
        // (zp,X) indexed indirect
        S_INDX_ZP,
        S_INDX_DUMMY,
        S_INDX_LO,
        S_INDX_HI,
        S_INDX_RW,
        // (zp),Y indirect indexed
        S_INDY_ZP,
        S_INDY_LO,
        S_INDY_HI,
        S_INDY_DUMMY,
        S_INDY_RW,
        // Halt (unused)
        S_HALT
    } state_e;

    state_e state_q;

    // ------------------------------------------------------------------------
    // Architectural registers.
    // ------------------------------------------------------------------------
    logic [7:0]  a_q;
    logic [7:0]  x_q;
    logic [7:0]  y_q;
    logic [7:0]  s_q;
    logic [7:0]  p_q;
    logic [7:0]  ir_q;
    logic [15:0] pc_q;

    // Internal staging registers for multi-cycle addressing.
    logic [7:0]  ad_lo_q;     // low byte of target address being built
    logic [7:0]  ad_hi_q;     // high byte
    logic [7:0]  ptr_q;       // zp pointer index (indirect modes only)
    logic        idx_carry_q; // captured carry from low+idx, for page-cross fixup

    // ------------------------------------------------------------------------
    // Decode.
    // ------------------------------------------------------------------------
    addr_mode_e am;
    op_kind_e   opk;

    mos6502_decode u_decode (
        .ir        (ir_q),
        .addr_mode (am),
        .op_kind   (opk)
    );

    // is_store is convenient for the page-cross optimization (loads skip the
    // dummy cycle when no page is crossed; stores always take it).
    logic is_store;
    assign is_store = (opk == OP_STORE);

    // Target register for loads/stores derived from IR bits [1:0]:
    //   00 → Y, 01 → A, 10 → X.
    // This is the canonical 6502 encoding for the LD?/ST? families.
    logic [7:0] store_src;
    always_comb begin
        unique case (ir_q[1:0])
            2'b00:   store_src = y_q;
            2'b01:   store_src = a_q;
            2'b10:   store_src = x_q;
            default: store_src = 8'h00;
        endcase
    end

    // Index value (X or Y) for indexed addressing modes.
    logic [7:0] idx_value;
    always_comb begin
        unique case (am)
            AM_ZPX, AM_ABSX, AM_INDX: idx_value = x_q;
            AM_ZPY, AM_ABSY, AM_INDY: idx_value = y_q;
            default:                  idx_value = 8'h00;
        endcase
    end

    // ------------------------------------------------------------------------
    // Bus output and next state — combinational.
    // ------------------------------------------------------------------------
    logic [15:0] address_d;
    logic [7:0]  data_out_d;
    logic        rw_d;
    logic        sync_d;
    state_e      state_d;

    // Helpers
    logic [8:0]  adlo_plus_idx;
    assign adlo_plus_idx = {1'b0, ad_lo_q} + {1'b0, idx_value};

    // Next state after S_FETCH given the live opcode on data_in.
    // We decode `data_in` directly (the byte being fetched this cycle) rather
    // than relying on the just-latched ir_q, because the dispatch needs to
    // happen on the same cycle as the FETCH→T1 transition.
    addr_mode_e am_next;
    op_kind_e   opk_next;
    mos6502_decode u_decode_next (
        .ir        (data_in),
        .addr_mode (am_next),
        .op_kind   (opk_next)
    );

    function automatic state_e first_state_for(input addr_mode_e m,
                                               input op_kind_e o);
        unique case (m)
            AM_IMPL: begin
                // Implied: transfers and NOP/flag/etc all do a dummy at PC.
                first_state_for = S_T1_DUMMY;
            end
            AM_IMM:   first_state_for = S_IMM_RW;
            AM_ZP:    first_state_for = S_ZP_ADDR;
            AM_ZPX:   first_state_for = S_ZPI_ADDR;
            AM_ZPY:   first_state_for = S_ZPI_ADDR;
            AM_ABS:   first_state_for = S_ABS_LO;
            AM_ABSX:  first_state_for = S_ABSI_LO;
            AM_ABSY:  first_state_for = S_ABSI_LO;
            AM_INDX:  first_state_for = S_INDX_ZP;
            AM_INDY:  first_state_for = S_INDY_ZP;
            default:  first_state_for = S_T1_DUMMY;
        endcase
        // Silence "unused" — kept for future per-op branching.
        if (o == OP_UNK) first_state_for = first_state_for;
    endfunction

    always_comb begin
        // Defaults
        address_d  = pc_q;
        data_out_d = 8'h00;
        rw_d       = 1'b1;
        sync_d     = 1'b0;
        state_d    = state_q;

        unique case (state_q)
            // ---- Reset sequence -------------------------------------------
            S_RESET_0: begin address_d = pc_q;                state_d = S_RESET_1; end
            S_RESET_1: begin address_d = {8'h01, s_q};        state_d = S_RESET_2; end
            S_RESET_2: begin address_d = {8'h01, s_q};        state_d = S_RESET_3; end
            S_RESET_3: begin address_d = {8'h01, s_q};        state_d = S_RESET_4; end
            S_RESET_4: begin address_d = 16'hFFFC;            state_d = S_RESET_5; end
            S_RESET_5: begin address_d = 16'hFFFD;            state_d = S_FETCH;   end

            // ---- Opcode fetch ---------------------------------------------
            S_FETCH: begin
                address_d = pc_q;
                sync_d    = 1'b1;
                state_d   = first_state_for(am_next, opk_next);
            end

            // ---- 2-cycle implied (NOP, transfers, unimplemented) -----------
            S_T1_DUMMY: begin
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            // ---- Immediate operand ----------------------------------------
            S_IMM_RW: begin
                address_d = pc_q;
                state_d   = S_FETCH;
            end

            // ---- Zero page direct -----------------------------------------
            S_ZP_ADDR: begin
                address_d = pc_q;
                state_d   = S_ZP_RW;
            end
            S_ZP_RW: begin
                address_d = {8'h00, ad_lo_q};
                rw_d      = !is_store;
                data_out_d = store_src;
                state_d   = S_FETCH;
            end

            // ---- Zero page indexed ---------------------------------------
            S_ZPI_ADDR: begin
                address_d = pc_q;
                state_d   = S_ZPI_DUMMY;
            end
            S_ZPI_DUMMY: begin
                address_d = {8'h00, ad_lo_q};
                state_d   = S_ZPI_RW;
            end
            S_ZPI_RW: begin
                address_d  = {8'h00, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = S_FETCH;
            end

            // ---- Absolute direct ------------------------------------------
            S_ABS_LO: begin
                address_d = pc_q;
                state_d   = S_ABS_HI;
            end
            S_ABS_HI: begin
                address_d = pc_q;
                state_d   = S_ABS_RW;
            end
            S_ABS_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = S_FETCH;
            end

            // ---- Absolute indexed -----------------------------------------
            S_ABSI_LO: begin
                address_d = pc_q;
                state_d   = S_ABSI_HI;
            end
            S_ABSI_HI: begin
                address_d = pc_q;
                state_d   = S_ABSI_DUMMY;
            end
            S_ABSI_DUMMY: begin
                // AB at unfixed-up address (ad_hi:ad_lo+idx[7:0]).
                address_d = {ad_hi_q, ad_lo_q};
                // For loads with no page cross, skip the dummy cycle and go
                // straight to the read. For stores, always take it.
                if (!is_store && !idx_carry_q) begin
                    rw_d      = 1'b1;
                    state_d   = S_FETCH;   // we'll do the load here, see latching
                end else begin
                    state_d   = S_ABSI_RW;
                end
            end
            S_ABSI_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = S_FETCH;
            end

            // ---- (zp,X) indexed indirect ----------------------------------
            S_INDX_ZP: begin
                address_d = pc_q;
                state_d   = S_INDX_DUMMY;
            end
            S_INDX_DUMMY: begin
                address_d = {8'h00, ptr_q};
                state_d   = S_INDX_LO;
            end
            S_INDX_LO: begin
                address_d = {8'h00, ptr_q};
                state_d   = S_INDX_HI;
            end
            S_INDX_HI: begin
                address_d = {8'h00, ptr_q + 8'h01};
                state_d   = S_INDX_RW;
            end
            S_INDX_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = S_FETCH;
            end

            // ---- (zp),Y indirect indexed ----------------------------------
            S_INDY_ZP: begin
                address_d = pc_q;
                state_d   = S_INDY_LO;
            end
            S_INDY_LO: begin
                address_d = {8'h00, ptr_q};
                state_d   = S_INDY_HI;
            end
            S_INDY_HI: begin
                address_d = {8'h00, ptr_q + 8'h01};
                state_d   = S_INDY_DUMMY;
            end
            S_INDY_DUMMY: begin
                address_d = {ad_hi_q, ad_lo_q};
                if (!is_store && !idx_carry_q) begin
                    rw_d    = 1'b1;
                    state_d = S_FETCH;     // skip dummy, read here
                end else begin
                    state_d = S_INDY_RW;
                end
            end
            S_INDY_RW: begin
                address_d  = {ad_hi_q, ad_lo_q};
                rw_d       = !is_store;
                data_out_d = store_src;
                state_d    = S_FETCH;
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
    // Synchronous updates.
    //
    // The "load result" (and flag updates) happens on whichever cycle reads
    // the target byte from the bus. That's *_RW states for non-IMM, the
    // IMM_RW state for IMM, the ABSI_DUMMY state for loads with no page
    // cross (because it's also where the read completes), and the INDY_DUMMY
    // state likewise.
    // ------------------------------------------------------------------------

    // Decide whether the present cycle commits a load result. `commit_load`
    // means: at the next rising edge, write data_in into the target register
    // and update N/Z. Stores never commit.
    logic commit_load;
    always_comb begin
        commit_load = 1'b0;
        if (!is_store) begin
            unique case (state_q)
                S_IMM_RW,
                S_ZP_RW,
                S_ZPI_RW,
                S_ABS_RW,
                S_INDX_RW,
                S_ABSI_RW,
                S_INDY_RW:
                    commit_load = (opk == OP_LOAD);
                // For loads-without-page-cross, the read completes at the
                // ABSI_DUMMY / INDY_DUMMY state itself (we collapse the
                // dummy into a real read in that case).
                S_ABSI_DUMMY,
                S_INDY_DUMMY:
                    commit_load = (opk == OP_LOAD) && !idx_carry_q;
                default: ;
            endcase
        end
    end

    // Destination register encoding for committing loads, derived from IR.
    // 00 → A, 01 → X, 10 → Y. Computed combinationally so the case in the
    // ff block dispatches on a stable value (avoids Verilator SIDEEFFECT).
    logic [1:0] load_target;
    always_comb begin
        unique case (ir_q[1:0])
            2'b00:   load_target = 2'b10; // LDY family
            2'b01:   load_target = 2'b00; // LDA family
            2'b10:   load_target = 2'b01; // LDX family
            default: load_target = 2'b00;
        endcase
    end

    // The value whose N/Z drives the flag update this cycle (mux'd by state).
    logic [7:0] nz_value;
    logic       nz_update;
    always_comb begin
        nz_value  = 8'h00;
        nz_update = 1'b0;
        if (commit_load) begin
            nz_value  = data_in;
            nz_update = 1'b1;
        end else if (xfer_active && xfer_upd_nz) begin
            nz_value  = xfer_value;
            nz_update = 1'b1;
        end
    end

    // Transfer instructions execute their move at the rising edge that
    // exits S_T1_DUMMY back to S_FETCH (i.e. the second cycle of the
    // 2-cycle implied form). The IR identifies which transfer.
    logic        xfer_active;
    logic [7:0]  xfer_value;
    logic [1:0]  xfer_dst;     // 00=A, 01=X, 10=Y, 11=S
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

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state_q     <= S_RESET_0;
            a_q         <= 8'h00;
            x_q         <= 8'h00;
            y_q         <= 8'h00;
            s_q         <= 8'h00;
            p_q         <= 8'h24;     // I + unused
            ir_q        <= 8'h00;
            pc_q        <= 16'h0000;
            ad_lo_q     <= 8'h00;
            ad_hi_q     <= 8'h00;
            ptr_q       <= 8'h00;
            idx_carry_q <= 1'b0;
        end else if (ready) begin
            state_q <= state_d;

            // Reset-sequence S decrement and PC vector latching.
            unique case (state_q)
                S_RESET_1, S_RESET_2, S_RESET_3: s_q <= s_q - 8'h01;
                S_RESET_4: pc_q[7:0]  <= data_in;
                S_RESET_5: pc_q[15:8] <= data_in;
                default: ;
            endcase

            // PC advance and IR latch happen at S_FETCH transitions, and at
            // states that consume an operand byte from PC (the *_LO / *_HI
            // fetches, IMM, ZP_ADDR, ZPI_ADDR, INDX_ZP, INDY_ZP).
            unique case (state_q)
                S_FETCH: begin
                    ir_q <= data_in;
                    pc_q <= pc_q + 16'd1;
                end
                S_IMM_RW: begin
                    pc_q <= pc_q + 16'd1;
                end
                S_ZP_ADDR, S_ZPI_ADDR: begin
                    ad_lo_q <= data_in;
                    pc_q    <= pc_q + 16'd1;
                end
                S_ZPI_DUMMY: begin
                    // Apply the index after the dummy zp read. 8-bit wrap is
                    // automatic because ad_lo_q is 8 bits.
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
                    // Tentatively compute ad_lo + idx; capture carry for fixup.
                    ad_lo_q     <= adlo_plus_idx[7:0];
                    idx_carry_q <= adlo_plus_idx[8];
                end
                S_ABSI_DUMMY: begin
                    // If there was a page cross, increment ad_hi for the
                    // upcoming real read/write.
                    if (idx_carry_q) ad_hi_q <= ad_hi_q + 8'h01;
                end
                S_INDX_DUMMY: begin
                    // Add X to the zp pointer (8-bit wrap).
                    ptr_q <= ptr_q + x_q;
                end
                S_INDX_LO: ad_lo_q <= data_in;
                S_INDX_HI: ad_hi_q <= data_in;
                S_INDY_LO: ad_lo_q <= data_in;
                S_INDY_HI: begin
                    ad_hi_q     <= data_in;
                    ad_lo_q     <= adlo_plus_idx[7:0]; // ad_lo + Y
                    idx_carry_q <= adlo_plus_idx[8];
                end
                S_INDY_DUMMY: begin
                    if (idx_carry_q) ad_hi_q <= ad_hi_q + 8'h01;
                end
                default: ;
            endcase

            // Load commit (for LDA/LDX/LDY).
            if (commit_load) begin
                unique case (load_target)
                    2'b00: a_q <= data_in;
                    2'b01: x_q <= data_in;
                    2'b10: y_q <= data_in;
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

            // N/Z flag update.
            if (nz_update) begin
                p_q[1] <= (nz_value == 8'h00);
                p_q[7] <= nz_value[7];
            end
        end
    end

    // ------------------------------------------------------------------------
    // Tie-offs.
    // ------------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    wire _unused = &{1'b0, irq_n, nmi_n, so_n, p_q};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
