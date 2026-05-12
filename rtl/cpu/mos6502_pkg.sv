// SPDX-License-Identifier: MIT
//
// mos6502_pkg — shared typedefs (addressing modes, op kinds, ALU ops).
//
// Kept in one file so Verilator can compile it before any modules that
// `import` from it. Packages must appear before their users on the
// compilation command line.

`default_nettype none

package mos6502_decode_pkg;

    typedef enum logic [4:0] {
        AM_IMPL,
        AM_ACC,
        AM_IMM,
        AM_ZP,
        AM_ZPX,
        AM_ZPY,
        AM_ABS,
        AM_ABSX,
        AM_ABSY,
        AM_IND,
        AM_INDX,
        AM_INDY,
        AM_REL,
        AM_UNK
    } addr_mode_e;

    typedef enum logic [4:0] {
        OP_NOP,
        OP_LOAD,
        OP_STORE,
        OP_XFER,
        OP_ALU,
        OP_RMW,
        OP_BRANCH,
        OP_JMP,
        OP_JSR,
        OP_RTS,
        OP_RTI,
        OP_BRK,
        OP_PUSH,
        OP_PULL,
        OP_FLAG,
        OP_UNK
    } op_kind_e;

endpackage : mos6502_decode_pkg

package mos6502_alu_pkg;

    typedef enum logic [4:0] {
        ALU_NONE,
        ALU_ADC, ALU_SBC,
        ALU_AND, ALU_ORA, ALU_EOR,
        ALU_ASL, ALU_LSR, ALU_ROL, ALU_ROR,
        ALU_INC, ALU_DEC,
        ALU_CMP, ALU_BIT,
        ALU_PASS_A, ALU_PASS_B
    } alu_op_e;

endpackage : mos6502_alu_pkg

`default_nettype wire
