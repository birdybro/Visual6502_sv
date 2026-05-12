// SPDX-License-Identifier: MIT
//
// mos6502_alu — combinational arithmetic / logic unit.
//
// Placeholder for M3. Real operations fill in at M5. For now the module
// exists so wiring stabilizes early; M3 only instantiates it with op = NONE.
//
// Typedef alu_op_e lives in mos6502_pkg.sv (mos6502_alu_pkg).

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

    // M5 fills this in. M3 just needs no-op outputs that don't propagate X.
    always_comb begin
        result    = 8'h00;
        carry_out = 1'b0;
        overflow  = 1'b0;
        zero      = 1'b1;
        negative  = 1'b0;
        unique case (op)
            ALU_PASS_A: result = a;
            ALU_PASS_B: result = b;
            default:    result = 8'h00;
        endcase
    end

    // verilator lint_off UNUSEDSIGNAL
    wire _unused_alu = &{1'b0, carry_in, decimal, a, b};
    // verilator lint_on UNUSEDSIGNAL

endmodule

`default_nettype wire
