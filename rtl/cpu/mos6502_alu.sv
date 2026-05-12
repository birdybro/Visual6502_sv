// SPDX-License-Identifier: MIT
//
// mos6502_alu — combinational arithmetic / logic unit.
//
// Implements the full 6502 ALU including NMOS decimal-mode ADC/SBC. N/Z come
// from the binary path (NMOS quirk preserved). V on decimal ADC/SBC is
// computed from the intermediate (post-low-nibble-adjust) value, matching
// the documented NMOS behavior.
//
// Outputs:
//   result     8-bit value (for ADC/SBC/AND/ORA/EOR/shifts/INC/DEC/BIT/etc.)
//   carry_out  carry/borrow flag
//   overflow   V flag (for ADC/SBC/BIT)
//   zero       Z flag (= result == 0, except where the FSM overrides)
//   negative   N flag (= result[7], except where the FSM overrides)
//
// The FSM is responsible for routing the right inputs (a/b/carry_in) and
// applying the right subset of flag outputs (e.g. CMP uses N/Z/C; BIT uses
// N/V/Z; ASL uses N/Z/C; etc.).

`default_nettype none

module mos6502_alu
    import mos6502_alu_pkg::*;
(
    input  alu_op_e      op,
    input  logic [7:0]   a,
    input  logic [7:0]   b,
    input  logic         carry_in,
    input  logic         decimal,
    output logic [7:0]   result,
    output logic         carry_out,
    output logic         overflow,
    output logic         zero,
    output logic         negative
);

    // ------------------------------------------------------------------------
    // Binary add / sub backbone.
    // ------------------------------------------------------------------------
    logic [8:0] sum_bin;       // a + b + cin
    logic [8:0] sub_bin;       // a + ~b + cin = a - b - !cin
    assign sum_bin = {1'b0, a} + {1'b0, b} + {8'b0, carry_in};
    assign sub_bin = {1'b0, a} + {1'b0, ~b} + {8'b0, carry_in};

    logic v_adc_bin;
    logic v_sbc_bin;
    assign v_adc_bin = (~(a[7] ^ b[7])) & (a[7] ^ sum_bin[7]);
    assign v_sbc_bin = (a[7] ^ b[7]) & (a[7] ^ sub_bin[7]);

    // ------------------------------------------------------------------------
    // Decimal ADC (NMOS).
    //
    // 1. Add low nibbles with carry. If > 9, add 6.
    // 2. Add high nibbles with the low-nibble carry.
    // 3. Capture intermediate (pre-adjust) for V/N flags.
    // 4. If high > 9, add 6 (carry out becomes the BCD carry).
    // ------------------------------------------------------------------------
    logic [5:0] al_adc;        // raw low-nibble add (a_lo+b_lo+cin, max 0x1F)
    logic [5:0] al_adc_adj;    // adjusted low (+6 if >9)
    logic [5:0] ah_adc;        // raw high-nibble add+low_carry
    logic [5:0] ah_adc_adj;    // adjusted high (+6 if >9)
    logic [7:0] adc_dec_res;
    logic       adc_dec_carry;
    logic       v_adc_dec;

    always_comb begin
        al_adc     = {2'b0, a[3:0]} + {2'b0, b[3:0]} + {5'b0, carry_in};
        al_adc_adj = (al_adc[4:0] > 5'd9) ? (al_adc + 6'd6) : al_adc;
        ah_adc     = {2'b0, a[7:4]} + {2'b0, b[7:4]} + {5'b0, al_adc_adj[4]};
        // V on NMOS decimal ADC: computed from the intermediate (post-low-
        // nibble-adjust, pre-high-nibble-adjust) value's bit 7 vs operand signs.
        v_adc_dec  = (~(a[7] ^ b[7])) & (a[7] ^ ah_adc[3]);
        ah_adc_adj = (ah_adc[4:0] > 5'd9) ? (ah_adc + 6'd6) : ah_adc;
        adc_dec_res   = {ah_adc_adj[3:0], al_adc_adj[3:0]};
        adc_dec_carry = ah_adc_adj[4] | ah_adc[5];
    end

    // ------------------------------------------------------------------------
    // Decimal SBC (NMOS).
    //
    // Signed-friendly subtract per nibble with -6 adjust when borrow.
    // ------------------------------------------------------------------------
    logic signed [5:0] sl_sbc;
    logic signed [5:0] sl_sbc_adj;
    logic signed [5:0] sh_sbc;
    logic signed [5:0] sh_sbc_adj;
    logic [7:0] sbc_dec_res;
    logic       sbc_dec_carry;

    always_comb begin
        sl_sbc     = $signed({2'b0, a[3:0]}) - $signed({2'b0, b[3:0]})
                   - $signed({5'b0, ~carry_in});
        sl_sbc_adj = (sl_sbc < 0) ? (sl_sbc - 6'sd6) : sl_sbc;
        sh_sbc     = $signed({2'b0, a[7:4]}) - $signed({2'b0, b[7:4]})
                   - $signed({5'b0, sl_sbc_adj[5]});
        sh_sbc_adj = (sh_sbc < 0) ? (sh_sbc - 6'sd6) : sh_sbc;
        sbc_dec_res   = {sh_sbc_adj[3:0], sl_sbc_adj[3:0]};
        sbc_dec_carry = ~sh_sbc_adj[5];
    end

    // Bits of intermediates above bit [3:0] of *_adj are part of the carry
    // computation flow but only specific bits are consumed downstream.
    // verilator lint_off UNUSEDSIGNAL
    wire _unused_alu_internal = &{1'b0, al_adc_adj[5], ah_adc_adj[5],
                                    sl_sbc_adj[4], sh_sbc_adj[4]};
    // verilator lint_on UNUSEDSIGNAL

    // ------------------------------------------------------------------------
    // Shift / rotate.
    // ------------------------------------------------------------------------
    logic [7:0] asl_res, lsr_res, rol_res, ror_res;
    assign asl_res = {a[6:0], 1'b0};
    assign lsr_res = {1'b0, a[7:1]};
    assign rol_res = {a[6:0], carry_in};
    assign ror_res = {carry_in, a[7:1]};

    // ------------------------------------------------------------------------
    // Output mux.
    // ------------------------------------------------------------------------
    always_comb begin
        result    = a;
        carry_out = 1'b0;
        overflow  = 1'b0;

        unique case (op)
            ALU_ADC: begin
                if (decimal) begin
                    result    = adc_dec_res;
                    carry_out = adc_dec_carry;
                    overflow  = v_adc_dec;
                end else begin
                    result    = sum_bin[7:0];
                    carry_out = sum_bin[8];
                    overflow  = v_adc_bin;
                end
            end
            ALU_SBC: begin
                if (decimal) begin
                    result    = sbc_dec_res;
                    carry_out = sbc_dec_carry;
                    overflow  = v_sbc_bin;   // NMOS quirk: V from binary path
                end else begin
                    result    = sub_bin[7:0];
                    carry_out = sub_bin[8];
                    overflow  = v_sbc_bin;
                end
            end
            ALU_AND:    result = a & b;
            ALU_ORA:    result = a | b;
            ALU_EOR:    result = a ^ b;
            ALU_ASL:    begin result = asl_res; carry_out = a[7]; end
            ALU_LSR:    begin result = lsr_res; carry_out = a[0]; end
            ALU_ROL:    begin result = rol_res; carry_out = a[7]; end
            ALU_ROR:    begin result = ror_res; carry_out = a[0]; end
            ALU_INC:    result = a + 8'd1;
            ALU_DEC:    result = a - 8'd1;
            ALU_CMP: begin
                // a - b for flag purposes. Result is the subtraction's low 8.
                result    = sub_bin[7:0];
                carry_out = sub_bin[8];     // C set if no borrow (a >= b)
            end
            ALU_BIT: begin
                // result = a & b for Z. N/V come from b directly — the FSM
                // pulls those bits separately.
                result   = a & b;
                overflow = b[6];
            end
            ALU_PASS_A: result = a;
            ALU_PASS_B: result = b;
            default:    result = a;
        endcase
    end

    // For BIT specifically, N comes from b[7], not result[7]. The FSM
    // overrides N at the flag-update site when opk==OP_ALU && IR is a BIT.
    // For decimal NMOS ADC/SBC: N/Z come from binary path too — also handled
    // at the flag-update site. So `zero` and `negative` here reflect the
    // result of the OP chosen, which is correct for the binary-mode majority.
    assign zero     = (result == 8'h00);
    assign negative = result[7];

endmodule

`default_nettype wire
