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

// FSM state and interrupt-entry mode enums. Shared between the control unit
// and the data-path / address-generation submodules.
package mos6502_state_pkg;

    typedef enum logic [6:0] {
        // Reset
        S_RESET_0, S_RESET_1, S_RESET_2, S_RESET_3, S_RESET_4, S_RESET_5,
        // Fetch
        S_FETCH,
        // 2-cycle implied (NOP / transfers / unimplemented)
        S_T1_DUMMY,
        // Immediate operand
        S_IMM_RW,
        // Zero-page direct
        S_ZP_ADDR, S_ZP_RW,
        // Zero-page indexed
        S_ZPI_ADDR, S_ZPI_DUMMY, S_ZPI_RW,
        // Absolute direct
        S_ABS_LO, S_ABS_HI, S_ABS_RW,
        // Absolute indexed
        S_ABSI_LO, S_ABSI_HI, S_ABSI_DUMMY, S_ABSI_RW,
        // (zp,X) indexed indirect
        S_INDX_ZP, S_INDX_DUMMY, S_INDX_LO, S_INDX_HI, S_INDX_RW,
        // (zp),Y indirect indexed
        S_INDY_ZP, S_INDY_LO, S_INDY_HI, S_INDY_DUMMY, S_INDY_RW,
        // RMW tail
        S_RMW_DUMMY_WRITE, S_RMW_WRITE,
        // Stack (PHA/PHP/PLA/PLP)
        S_PUSH_T1, S_PUSH_T2,
        S_PULL_T1, S_PULL_T2, S_PULL_T3,
        // JSR
        S_JSR_LO, S_JSR_PEEK, S_JSR_PUSH_PCH, S_JSR_PUSH_PCL, S_JSR_HI,
        // RTS
        S_RTS_T1, S_RTS_PEEK, S_RTS_PULL_PCL, S_RTS_PULL_PCH, S_RTS_INC,
        // RTI
        S_RTI_T1, S_RTI_PEEK, S_RTI_PULL_P, S_RTI_PULL_PCL, S_RTI_PULL_PCH,
        // BRK / IRQ / NMI entry
        S_INT_T0, S_INT_T1,
        S_INT_PUSH_PCH, S_INT_PUSH_PCL, S_INT_PUSH_P,
        S_INT_VEC_LO, S_INT_VEC_HI,
        // Conditional branches
        S_BR_OFFSET, S_BR_TAKEN, S_BR_FIXUP,
        // JMP absolute / indirect
        S_JMP_ABS_LO, S_JMP_ABS_HI,
        S_JMP_IND_LO, S_JMP_IND_HI, S_JMP_IND_PCL, S_JMP_IND_PCH,
        // Unused
        S_HALT
    } state_e;

    typedef enum logic [1:0] {
        INT_BRK, INT_IRQ, INT_NMI, INT_RESET
    } int_mode_e;

endpackage : mos6502_state_pkg

`default_nettype wire
