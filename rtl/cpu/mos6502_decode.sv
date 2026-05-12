// SPDX-License-Identifier: MIT
//
// mos6502_decode — combinational opcode decode.
//
// Given an 8-bit instruction register, produces the control signals the FSM
// uses to drive its microsequence. This is the clean-RTL replacement for the
// Visual6502 PLA (see docs/visual6502_mapping.md). It is intentionally a flat
// `case` rather than a literal PLA — equivalence with the reference is
// established empirically via trace comparison, not by matching gates.
//
// Typedefs live in mos6502_pkg.sv (mos6502_decode_pkg).

`default_nettype none

module mos6502_decode
    import mos6502_decode_pkg::*;
(
    input  logic [7:0]   ir,
    output addr_mode_e   addr_mode,
    output op_kind_e     op_kind
);

    always_comb begin
        addr_mode = AM_UNK;
        op_kind   = OP_UNK;
        unique case (ir)
            // ----- M3: implemented -----
            8'hEA: begin addr_mode = AM_IMPL; op_kind = OP_NOP; end

            // ----- M4: LDA/LDX/LDY, STA/STX/STY, transfers -----
            // LDA
            8'hA9: begin addr_mode = AM_IMM;  op_kind = OP_LOAD; end
            8'hA5: begin addr_mode = AM_ZP;   op_kind = OP_LOAD; end
            8'hB5: begin addr_mode = AM_ZPX;  op_kind = OP_LOAD; end
            8'hAD: begin addr_mode = AM_ABS;  op_kind = OP_LOAD; end
            8'hBD: begin addr_mode = AM_ABSX; op_kind = OP_LOAD; end
            8'hB9: begin addr_mode = AM_ABSY; op_kind = OP_LOAD; end
            8'hA1: begin addr_mode = AM_INDX; op_kind = OP_LOAD; end
            8'hB1: begin addr_mode = AM_INDY; op_kind = OP_LOAD; end
            // LDX
            8'hA2: begin addr_mode = AM_IMM;  op_kind = OP_LOAD; end
            8'hA6: begin addr_mode = AM_ZP;   op_kind = OP_LOAD; end
            8'hB6: begin addr_mode = AM_ZPY;  op_kind = OP_LOAD; end
            8'hAE: begin addr_mode = AM_ABS;  op_kind = OP_LOAD; end
            8'hBE: begin addr_mode = AM_ABSY; op_kind = OP_LOAD; end
            // LDY
            8'hA0: begin addr_mode = AM_IMM;  op_kind = OP_LOAD; end
            8'hA4: begin addr_mode = AM_ZP;   op_kind = OP_LOAD; end
            8'hB4: begin addr_mode = AM_ZPX;  op_kind = OP_LOAD; end
            8'hAC: begin addr_mode = AM_ABS;  op_kind = OP_LOAD; end
            8'hBC: begin addr_mode = AM_ABSX; op_kind = OP_LOAD; end
            // STA
            8'h85: begin addr_mode = AM_ZP;   op_kind = OP_STORE; end
            8'h95: begin addr_mode = AM_ZPX;  op_kind = OP_STORE; end
            8'h8D: begin addr_mode = AM_ABS;  op_kind = OP_STORE; end
            8'h9D: begin addr_mode = AM_ABSX; op_kind = OP_STORE; end
            8'h99: begin addr_mode = AM_ABSY; op_kind = OP_STORE; end
            8'h81: begin addr_mode = AM_INDX; op_kind = OP_STORE; end
            8'h91: begin addr_mode = AM_INDY; op_kind = OP_STORE; end
            // STX
            8'h86: begin addr_mode = AM_ZP;   op_kind = OP_STORE; end
            8'h96: begin addr_mode = AM_ZPY;  op_kind = OP_STORE; end
            8'h8E: begin addr_mode = AM_ABS;  op_kind = OP_STORE; end
            // STY
            8'h84: begin addr_mode = AM_ZP;   op_kind = OP_STORE; end
            8'h94: begin addr_mode = AM_ZPX;  op_kind = OP_STORE; end
            8'h8C: begin addr_mode = AM_ABS;  op_kind = OP_STORE; end
            // Transfers / TSX/TXS
            8'hAA, 8'h8A, 8'hA8, 8'h98, 8'hBA, 8'h9A:
                begin addr_mode = AM_IMPL; op_kind = OP_XFER; end
            // INX/INY/DEX/DEY (implied RMW on register)
            8'hE8, 8'hC8, 8'hCA, 8'h88:
                begin addr_mode = AM_IMPL; op_kind = OP_RMW; end

            // ----- M5: ALU + flag instructions -----
            // ADC
            8'h69: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'h65: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'h75: begin addr_mode = AM_ZPX;  op_kind = OP_ALU; end
            8'h6D: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            8'h7D: begin addr_mode = AM_ABSX; op_kind = OP_ALU; end
            8'h79: begin addr_mode = AM_ABSY; op_kind = OP_ALU; end
            8'h61: begin addr_mode = AM_INDX; op_kind = OP_ALU; end
            8'h71: begin addr_mode = AM_INDY; op_kind = OP_ALU; end
            // SBC
            8'hE9: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'hE5: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'hF5: begin addr_mode = AM_ZPX;  op_kind = OP_ALU; end
            8'hED: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            8'hFD: begin addr_mode = AM_ABSX; op_kind = OP_ALU; end
            8'hF9: begin addr_mode = AM_ABSY; op_kind = OP_ALU; end
            8'hE1: begin addr_mode = AM_INDX; op_kind = OP_ALU; end
            8'hF1: begin addr_mode = AM_INDY; op_kind = OP_ALU; end
            // AND
            8'h29: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'h25: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'h35: begin addr_mode = AM_ZPX;  op_kind = OP_ALU; end
            8'h2D: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            8'h3D: begin addr_mode = AM_ABSX; op_kind = OP_ALU; end
            8'h39: begin addr_mode = AM_ABSY; op_kind = OP_ALU; end
            8'h21: begin addr_mode = AM_INDX; op_kind = OP_ALU; end
            8'h31: begin addr_mode = AM_INDY; op_kind = OP_ALU; end
            // ORA
            8'h09: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'h05: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'h15: begin addr_mode = AM_ZPX;  op_kind = OP_ALU; end
            8'h0D: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            8'h1D: begin addr_mode = AM_ABSX; op_kind = OP_ALU; end
            8'h19: begin addr_mode = AM_ABSY; op_kind = OP_ALU; end
            8'h01: begin addr_mode = AM_INDX; op_kind = OP_ALU; end
            8'h11: begin addr_mode = AM_INDY; op_kind = OP_ALU; end
            // EOR
            8'h49: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'h45: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'h55: begin addr_mode = AM_ZPX;  op_kind = OP_ALU; end
            8'h4D: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            8'h5D: begin addr_mode = AM_ABSX; op_kind = OP_ALU; end
            8'h59: begin addr_mode = AM_ABSY; op_kind = OP_ALU; end
            8'h41: begin addr_mode = AM_INDX; op_kind = OP_ALU; end
            8'h51: begin addr_mode = AM_INDY; op_kind = OP_ALU; end
            // CMP
            8'hC9: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'hC5: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'hD5: begin addr_mode = AM_ZPX;  op_kind = OP_ALU; end
            8'hCD: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            8'hDD: begin addr_mode = AM_ABSX; op_kind = OP_ALU; end
            8'hD9: begin addr_mode = AM_ABSY; op_kind = OP_ALU; end
            8'hC1: begin addr_mode = AM_INDX; op_kind = OP_ALU; end
            8'hD1: begin addr_mode = AM_INDY; op_kind = OP_ALU; end
            // CPX
            8'hE0: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'hE4: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'hEC: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            // CPY
            8'hC0: begin addr_mode = AM_IMM;  op_kind = OP_ALU; end
            8'hC4: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'hCC: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            // BIT
            8'h24: begin addr_mode = AM_ZP;   op_kind = OP_ALU; end
            8'h2C: begin addr_mode = AM_ABS;  op_kind = OP_ALU; end
            // Shifts / Rotates (RMW family)
            // ASL
            8'h0A: begin addr_mode = AM_ACC;  op_kind = OP_RMW; end
            8'h06: begin addr_mode = AM_ZP;   op_kind = OP_RMW; end
            8'h16: begin addr_mode = AM_ZPX;  op_kind = OP_RMW; end
            8'h0E: begin addr_mode = AM_ABS;  op_kind = OP_RMW; end
            8'h1E: begin addr_mode = AM_ABSX; op_kind = OP_RMW; end
            // LSR
            8'h4A: begin addr_mode = AM_ACC;  op_kind = OP_RMW; end
            8'h46: begin addr_mode = AM_ZP;   op_kind = OP_RMW; end
            8'h56: begin addr_mode = AM_ZPX;  op_kind = OP_RMW; end
            8'h4E: begin addr_mode = AM_ABS;  op_kind = OP_RMW; end
            8'h5E: begin addr_mode = AM_ABSX; op_kind = OP_RMW; end
            // ROL
            8'h2A: begin addr_mode = AM_ACC;  op_kind = OP_RMW; end
            8'h26: begin addr_mode = AM_ZP;   op_kind = OP_RMW; end
            8'h36: begin addr_mode = AM_ZPX;  op_kind = OP_RMW; end
            8'h2E: begin addr_mode = AM_ABS;  op_kind = OP_RMW; end
            8'h3E: begin addr_mode = AM_ABSX; op_kind = OP_RMW; end
            // ROR
            8'h6A: begin addr_mode = AM_ACC;  op_kind = OP_RMW; end
            8'h66: begin addr_mode = AM_ZP;   op_kind = OP_RMW; end
            8'h76: begin addr_mode = AM_ZPX;  op_kind = OP_RMW; end
            8'h6E: begin addr_mode = AM_ABS;  op_kind = OP_RMW; end
            8'h7E: begin addr_mode = AM_ABSX; op_kind = OP_RMW; end
            // INC/DEC (memory)
            8'hE6: begin addr_mode = AM_ZP;   op_kind = OP_RMW; end
            8'hF6: begin addr_mode = AM_ZPX;  op_kind = OP_RMW; end
            8'hEE: begin addr_mode = AM_ABS;  op_kind = OP_RMW; end
            8'hFE: begin addr_mode = AM_ABSX; op_kind = OP_RMW; end
            8'hC6: begin addr_mode = AM_ZP;   op_kind = OP_RMW; end
            8'hD6: begin addr_mode = AM_ZPX;  op_kind = OP_RMW; end
            8'hCE: begin addr_mode = AM_ABS;  op_kind = OP_RMW; end
            8'hDE: begin addr_mode = AM_ABSX; op_kind = OP_RMW; end
            // Flag set/clear
            8'h18, 8'h38, 8'h58, 8'h78, 8'hB8, 8'hD8, 8'hF8:
                begin addr_mode = AM_IMPL; op_kind = OP_FLAG; end

            // ----- M6: stack + interrupts -----
            8'h48, 8'h08: begin addr_mode = AM_IMPL; op_kind = OP_PUSH; end
            8'h68, 8'h28: begin addr_mode = AM_IMPL; op_kind = OP_PULL; end
            8'h20:        begin addr_mode = AM_ABS;  op_kind = OP_JSR;  end
            8'h60:        begin addr_mode = AM_IMPL; op_kind = OP_RTS;  end
            8'h40:        begin addr_mode = AM_IMPL; op_kind = OP_RTI;  end
            8'h00:        begin addr_mode = AM_IMPL; op_kind = OP_BRK;  end

            // ----- M7: branches + JMP -----
            8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0:
                begin addr_mode = AM_REL; op_kind = OP_BRANCH; end
            8'h4C: begin addr_mode = AM_ABS; op_kind = OP_JMP; end
            8'h6C: begin addr_mode = AM_IND; op_kind = OP_JMP; end

            // ----- M8: undocumented opcodes (stable subset) -----
            // 1-byte NOP duplicates of $EA.
            8'h1A, 8'h3A, 8'h5A, 8'h7A, 8'hDA, 8'hFA:
                begin addr_mode = AM_IMPL; op_kind = OP_NOP; end
            // 2-byte immediate NOPs (read at PC then discard).
            8'h80, 8'h82, 8'h89, 8'hC2, 8'hE2:
                begin addr_mode = AM_IMM; op_kind = OP_NOP; end
            // 2-byte zp NOPs.
            8'h04, 8'h44, 8'h64:
                begin addr_mode = AM_ZP; op_kind = OP_NOP; end
            // 2-byte zp,X NOPs.
            8'h14, 8'h34, 8'h54, 8'h74, 8'hD4, 8'hF4:
                begin addr_mode = AM_ZPX; op_kind = OP_NOP; end
            // 3-byte abs NOP.
            8'h0C:
                begin addr_mode = AM_ABS; op_kind = OP_NOP; end
            // 3-byte abs,X NOPs (4 or 5 cycles depending on page cross).
            8'h1C, 8'h3C, 8'h5C, 8'h7C, 8'hDC, 8'hFC:
                begin addr_mode = AM_ABSX; op_kind = OP_NOP; end
            // SAX: store (A AND X). Uses STORE op kind; store_src logic
            // routes IR[1:0]==11 to (a_q & x_q).
            8'h87: begin addr_mode = AM_ZP;   op_kind = OP_STORE; end
            8'h97: begin addr_mode = AM_ZPY;  op_kind = OP_STORE; end
            8'h8F: begin addr_mode = AM_ABS;  op_kind = OP_STORE; end
            8'h83: begin addr_mode = AM_INDX; op_kind = OP_STORE; end
            // LAX: load both A and X. Uses LOAD op kind; load_target with
            // IR[1:0]==11 writes both A and X.
            8'hA7: begin addr_mode = AM_ZP;   op_kind = OP_LOAD; end
            8'hB7: begin addr_mode = AM_ZPY;  op_kind = OP_LOAD; end
            8'hAF: begin addr_mode = AM_ABS;  op_kind = OP_LOAD; end
            8'hBF: begin addr_mode = AM_ABSY; op_kind = OP_LOAD; end
            8'hA3: begin addr_mode = AM_INDX; op_kind = OP_LOAD; end
            8'hB3: begin addr_mode = AM_INDY; op_kind = OP_LOAD; end

            default: begin addr_mode = AM_UNK; op_kind = OP_UNK; end
        endcase
    end

endmodule

`default_nettype wire
