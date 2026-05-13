#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate small 6502 test program binaries by hand-assembling opcodes.

Each test fills $0000-end with the program, pads the rest of the addressable
range with $EA (NOP) so execution doesn't fall off the end into something
unimplemented. The reset vector lives in $FFFC/D (the trace harness sets it).
"""

import argparse
import os
import struct
import sys


def make_bin(bytes_, size=0x10000, pad=0xEA):
    out = bytearray([pad] * size)
    for i, b in enumerate(bytes_):
        out[i] = b & 0xFF
    return bytes(out)


def make_bin_blocks(blocks, vectors=None, size=0x10000, pad=0xEA):
    """Lay out multiple blocks at specific addresses.

    blocks: list of (addr, list-of-bytes)
    vectors: optional dict {0xFFFA: ..., 0xFFFC: ..., 0xFFFE: ...} for vectors
    """
    out = bytearray([pad] * size)
    for addr, data in blocks:
        for i, b in enumerate(data):
            out[(addr + i) & 0xFFFF] = b & 0xFF
    if vectors:
        for addr, val in vectors.items():
            out[addr & 0xFFFF] = val & 0xFF
    return bytes(out)


def m3_nop():
    # M3 sanity: 256 NOPs, then NOPs (same as the original nop_loop).
    return [0xEA] * 256


def m4_loadstore():
    # Exercises LDA/LDX/LDY immediate + zp + abs + transfers + indexed forms.
    prog = [
        # Immediate loads.
        0xA9, 0x42,             # LDA #$42
        0xA2, 0x11,             # LDX #$11
        0xA0, 0x22,             # LDY #$22
        # Zero-page stores.
        0x85, 0x80,             # STA $80
        0x86, 0x81,             # STX $81
        0x84, 0x82,             # STY $82
        # Absolute stores.
        0x8D, 0x90, 0x00,       # STA $0090
        0x8E, 0x91, 0x00,       # STX $0091
        0x8C, 0x92, 0x00,       # STY $0092
        # Transfers.
        0xA9, 0x99,             # LDA #$99
        0xAA,                   # TAX
        0xA8,                   # TAY
        0x8A,                   # TXA
        0x98,                   # TYA
        0xBA,                   # TSX
        0x9A,                   # TXS
        # Zero-page direct loads (read back what we stored).
        0xA5, 0x80,             # LDA $80
        0xA6, 0x81,             # LDX $81
        0xA4, 0x82,             # LDY $82
        # Absolute direct loads.
        0xAD, 0x90, 0x00,       # LDA $0090
        0xAE, 0x91, 0x00,       # LDX $0091
        0xAC, 0x92, 0x00,       # LDY $0092
        # Zero-page indexed.
        0xA2, 0x02,             # LDX #$02
        0xB5, 0x7E,             # LDA $7E,X  -> reads $80
        0xA0, 0x01,             # LDY #$01
        0xB6, 0x7F,             # LDX $7F,Y  -> reads $80
        # Absolute indexed.
        0xA2, 0x10,             # LDX #$10  (offset)
        0xBD, 0x80, 0x00,       # LDA $0080,X -> reads $0090
        0xA0, 0x11,             # LDY #$11
        0xB9, 0x80, 0x00,       # LDA $0080,Y -> reads $0091
        # Absolute indexed with page-cross (so the dummy cycle exercises).
        0xA2, 0xFF,             # LDX #$FF
        0xBD, 0x02, 0x00,       # LDA $0002,X -> reads $0101 (page cross)
        # (zp,X) indexed indirect.
        # Set up zp pointer at $20: low=$90 high=$00 -> target $0090
        0xA9, 0x90, 0x85, 0x20, # LDA #$90; STA $20
        0xA9, 0x00, 0x85, 0x21, # LDA #$00; STA $21
        0xA2, 0x00,             # LDX #$00
        0xA1, 0x20,             # LDA ($20,X) -> reads $0090
        # (zp),Y indirect indexed.
        # Pointer at $30: low=$80 high=$00 -> target $0080+Y
        0xA9, 0x80, 0x85, 0x30, # LDA #$80; STA $30
        0xA9, 0x00, 0x85, 0x31, # LDA #$00; STA $31
        0xA0, 0x02,             # LDY #$02
        0xB1, 0x30,             # LDA ($30),Y -> reads $0082
        # Indexed store.
        0xA9, 0x77,             # LDA #$77
        0xA2, 0x10,             # LDX #$10
        0x9D, 0x40, 0x00,       # STA $0040,X -> writes $0050
        # Done — fall through into NOP pad.
    ]
    return prog


def m5_alu():
    # Exercises ALU ops, RMW, decimal mode, and flag instructions.
    prog = [
        # ----- Flag setup -----
        0x18,                   # CLC
        0xD8,                   # CLD (binary mode)
        # ----- AND / ORA / EOR immediate -----
        0xA9, 0xF0,             # LDA #$F0
        0x29, 0x0F,             # AND #$0F   -> A = $00, Z=1
        0xA9, 0xF0,             # LDA #$F0
        0x09, 0x0F,             # ORA #$0F   -> A = $FF, N=1
        0xA9, 0xAA,             # LDA #$AA
        0x49, 0x55,             # EOR #$55   -> A = $FF, N=1
        # ----- ADC binary -----
        0xA9, 0x42,             # LDA #$42
        0x69, 0x01,             # ADC #$01   -> A = $43, C=0
        0xA9, 0xFF,             # LDA #$FF
        0x69, 0x01,             # ADC #$01   -> A = $00, C=1, Z=1
        0xA9, 0x7F,             # LDA #$7F
        0x69, 0x01,             # ADC #$01   -> A = $80, V=1, N=1
        # ----- SBC binary -----
        0x38,                   # SEC
        0xA9, 0x10,             # LDA #$10
        0xE9, 0x01,             # SBC #$01   -> A = $0F
        0xA9, 0x00,             # LDA #$00
        0xE9, 0x01,             # SBC #$01   -> A = $FE, C=0 (borrow)
        # ----- CMP/CPX/CPY -----
        0xA9, 0x50,             # LDA #$50
        0xC9, 0x50,             # CMP #$50   -> Z=1, C=1
        0xC9, 0x40,             # CMP #$40   -> C=1, Z=0
        0xC9, 0x60,             # CMP #$60   -> C=0, N=1
        0xA2, 0x10,             # LDX #$10
        0xE0, 0x10,             # CPX #$10   -> Z=1
        0xA0, 0x20,             # LDY #$20
        0xC0, 0x20,             # CPY #$20
        # ----- BIT -----
        0xA9, 0xC0,             # LDA #$C0  (N=1 V=1 from BIT)
        0x85, 0x80,             # STA $80
        0xA9, 0xFF,             # LDA #$FF
        0x24, 0x80,             # BIT $80   -> N=1, V=1, Z=0
        0xA9, 0x00,             # LDA #$00
        0x24, 0x80,             # BIT $80   -> N=1, V=1, Z=1
        # ----- Shifts (accumulator) -----
        0xA9, 0x81,             # LDA #$81
        0x0A,                   # ASL A     -> A = $02, C=1
        0x4A,                   # LSR A     -> A = $01, C=0
        0x18,                   # CLC
        0xA9, 0x80,             # LDA #$80
        0x2A,                   # ROL A     -> A = $00, C=1
        0x2A,                   # ROL A     -> A = $01, C=0
        0xA9, 0x01,             # LDA #$01
        0x6A,                   # ROR A     -> A = $00, C=1
        0x6A,                   # ROR A     -> A = $80, C=0
        # ----- Shifts (memory zp) -----
        0xA9, 0x55,             # LDA #$55
        0x85, 0x90,             # STA $90
        0x06, 0x90,             # ASL $90   -> mem[$90] = $AA
        0x46, 0x90,             # LSR $90   -> mem[$90] = $55
        # ----- INC/DEC memory -----
        0xA9, 0x00, 0x85, 0xA0, # LDA #$00; STA $A0
        0xE6, 0xA0,             # INC $A0   -> mem = $01
        0xE6, 0xA0,             # INC $A0   -> mem = $02
        0xC6, 0xA0,             # DEC $A0   -> mem = $01
        # ----- INX/INY/DEX/DEY -----
        0xA2, 0x00,             # LDX #$00
        0xE8,                   # INX       -> X = $01
        0xE8,                   # INX       -> X = $02
        0xCA,                   # DEX       -> X = $01
        0xA0, 0x80,             # LDY #$80
        0x88,                   # DEY       -> Y = $7F
        0xC8,                   # INY       -> Y = $80
        # ----- Decimal mode ADC/SBC -----
        0xF8,                   # SED
        0x18,                   # CLC
        0xA9, 0x09,             # LDA #$09
        0x69, 0x01,             # ADC #$01  -> A = $10 (BCD)
        0xA9, 0x49,             # LDA #$49
        0x69, 0x51,             # ADC #$51  -> A = $00, C=1
        0x38,                   # SEC
        0xA9, 0x10,             # LDA #$10
        0xE9, 0x01,             # SBC #$01  -> A = $09 (BCD)
        0xA9, 0x00,             # LDA #$00
        0xE9, 0x01,             # SBC #$01  -> A = $99 (BCD), C=0
        0xD8,                   # CLD (back to binary)
        # ----- Flag set/clear sweep -----
        0x38, 0x18,             # SEC, CLC
        0x78, 0x58,             # SEI, CLI
        0xB8,                   # CLV
        # Fall through to NOPs.
    ]
    return prog


def m6_stack_subroutines():
    """Builder that lays out main + sub + BRK handler at fixed addresses.

    Returns a fully-formed 64KB image and lets the caller skip the default
    contiguous-bytes packaging. Signaled by returning a special sentinel.
    """
    main = [
        # ----- Stack push/pull -----
        0xA9, 0x11,             # $0000: LDA #$11
        0x48,                   # $0002: PHA
        0xA9, 0x22,             # $0003: LDA #$22
        0x48,                   # $0005: PHA
        0x68,                   # $0006: PLA  -> A=$22
        0x68,                   # $0007: PLA  -> A=$11
        # ----- PHP / PLP -----
        0xA9, 0x55,             # $0008: LDA #$55
        0x38,                   # $000A: SEC
        0x08,                   # $000B: PHP
        0x18,                   # $000C: CLC
        0x28,                   # $000D: PLP  (restores C=1)
        # ----- JSR / RTS -----
        0x20, 0x30, 0x00,       # $000E: JSR $0030 (sub)
        0xA9, 0xAA,             # $0011: LDA #$AA  (after return)
        # ----- BRK / RTI -----
        0x00,                   # $0013: BRK (1-byte opcode, then signature)
        0xEA,                   # $0014: signature byte (skipped by BRK)
        0xA9, 0xBB,             # $0015: LDA #$BB (after RTI)
        # Fall through to NOP pad.
    ]
    sub = [
        0xA2, 0x42,             # $0030: LDX #$42
        0xA0, 0x33,             # $0032: LDY #$33
        0x60,                   # $0034: RTS
    ]
    brk_handler = [
        0xA9, 0x77,             # $0080: LDA #$77
        0xA2, 0x99,             # $0082: LDX #$99
        0x40,                   # $0084: RTI
    ]
    return make_bin_blocks(
        blocks=[(0x0000, main), (0x0030, sub), (0x0080, brk_handler)],
        vectors={
            0xFFFC: 0x00, 0xFFFD: 0x00,   # reset
            0xFFFE: 0x80, 0xFFFF: 0x00,   # IRQ/BRK -> $0080
            0xFFFA: 0x80, 0xFFFB: 0x00,   # NMI -> same handler
        },
    )


def m7_branches():
    """Branches (all 8), JMP abs, JMP indirect, JMP indirect $xxFF wrap bug,
    forward and backward branches with page-cross."""
    # Main block at $0080 so a branch can cross to $00FF / $0100 page edge.
    main = [
        # ----- BEQ / BNE -----
        0xA9, 0x00,             # $0080: LDA #$00       (Z=1)
        0xF0, 0x02,             # $0082: BEQ +2         (taken, no cross)
        0xA9, 0xFF,             # $0084: LDA #$FF       (skipped)
        0xA9, 0x01,             # $0086: LDA #$01       (Z=0)
        0xF0, 0x02,             # $0088: BEQ +2         (not taken)
        0xA9, 0x42,             # $008A: LDA #$42       (executes)
        0xD0, 0x02,             # $008C: BNE +2         (taken)
        0xA9, 0x99,             # $008E: LDA #$99       (skipped)
        # ----- BPL / BMI -----
        0xA9, 0x80,             # $0090: LDA #$80       (N=1)
        0x30, 0x02,             # $0092: BMI +2         (taken)
        0xA9, 0xCC,             # $0094: LDA #$CC       (skipped)
        0x10, 0x02,             # $0096: BPL +2         (not taken, N=1)
        0xA9, 0x11,             # $0098: LDA #$11       (executes; N=0 after)
        0x10, 0x02,             # $009A: BPL +2         (taken)
        0xA9, 0xCC,             # $009C: LDA #$CC       (skipped)
        # ----- BCC / BCS -----
        0x18,                   # $009E: CLC
        0x90, 0x02,             # $009F: BCC +2         (taken)
        0xA9, 0xCC,             # $00A1: LDA #$CC       (skipped)
        0x38,                   # $00A3: SEC
        0xB0, 0x02,             # $00A4: BCS +2         (taken)
        0xA9, 0xCC,             # $00A6: LDA #$CC
        # ----- BVC / BVS -----
        0xA9, 0x40,             # $00A8: LDA #$40 (V=0 from B8 below)
        0xB8,                   # $00AA: CLV
        0x50, 0x02,             # $00AB: BVC +2         (taken)
        0xA9, 0xCC,             # $00AD: LDA
        # ----- Forward branch with page cross (PC = $00B1+2+0x60 = $0113) -----
        0xA9, 0x00,             # $00AF: LDA #$00       (Z=1)
        0xF0, 0x60,             # $00B1: BEQ +96  → $0113 (page cross)
        0xEA,                   # $00B3.. (will be filled with NOPs anyway)
        # We need a target at $0113.
        # Continued at $0113.
    ]
    # Forward branch target: a backward branch with page cross.
    after_fwd = [
        # $0113 onward
        0xA9, 0x80,             # $0113: LDA #$80 (N=1)
        0x30, 0x80,             # $0115: BMI -128 → $0117 - 128 = $0097 (page cross back)
        # If we don't end up back-branching cleanly we'll land here in NOPs.
    ]
    # At $0097 we should land back in the middle of the main block. To avoid
    # ricocheting, set $0097 to a JMP abs that lands somewhere safe.
    landing_97 = [
        0x4C, 0x20, 0x02,       # $0097: JMP $0220  (avoid re-running the branch test)
    ]
    # JMP target at $0220: do an indirect JMP via $03FF (page-wrap bug).
    landing_220 = [
        0xA9, 0xAB,             # $0220: LDA #$AB
        0x6C, 0xFF, 0x03,       # $0222: JMP ($03FF)  → uses ($03FF, $0300) due to bug
        # Real CPU fetches PCL from $03FF and PCH from $0300 (wrap).
        # We set $03FF=$50, $0300=$03 so target = $0350.
    ]
    landing_350 = [
        0xA9, 0xCD,             # $0350: LDA #$CD (proof we landed via the bug)
        # Loop forever with NOPs after this point.
    ]
    # Indirect pointer bytes.
    indir = [(0x03FF, [0x50]), (0x0300, [0x03])]

    blocks = [
        (0x0080, main),
        (0x0113, after_fwd),
        (0x0097, landing_97),
        (0x0220, landing_220),
        (0x0350, landing_350),
    ] + indir

    return make_bin_blocks(
        blocks=blocks,
        vectors={
            0xFFFC: 0x80, 0xFFFD: 0x00,   # reset → $0080
            0xFFFE: 0x00, 0xFFFF: 0x10,   # IRQ/BRK (unused but defined)
            0xFFFA: 0x00, 0xFFFB: 0x10,
        },
    )


def m8_undoc():
    """Exercises stable undocumented NMOS opcodes: NOPs of all forms, SAX, LAX."""
    prog = [
        # 1-byte undoc NOPs
        0x1A,                   # NOP (undoc, implied)
        0x3A,
        # 2-byte imm NOPs (consume operand)
        0x80, 0x11,             # NOP #$11
        0x82, 0x22,
        0xC2, 0x33,
        # 2-byte zp NOPs
        0x04, 0x80,             # NOP $80
        0x44, 0x81,
        # 2-byte zp,X NOPs
        0xA2, 0x05,             # LDX #$05
        0x14, 0x10,             # NOP $10,X (reads $15)
        0x34, 0x20,
        # 3-byte abs NOP
        0x0C, 0x00, 0x02,       # NOP $0200
        # 3-byte abs,X NOP (no page cross)
        0x1C, 0x00, 0x02,       # NOP $0200,X (reads $0205)
        # SAX zp: store A AND X at $90
        0xA9, 0xFF,             # LDA #$FF
        0xA2, 0xAA,             # LDX #$AA
        0x87, 0x90,             # SAX $90  -> mem[$90] = $FF & $AA = $AA
        # SAX abs
        0x8F, 0x00, 0x02,       # SAX $0200 -> mem[$0200] = $AA
        # LAX zp: load both A and X
        0xA9, 0x77,             # LDA #$77 (will be overwritten)
        0xA7, 0x90,             # LAX $90  -> A = X = mem[$90] = $AA
        # LAX abs
        0xAF, 0x00, 0x02,       # LAX $0200 -> A = X = $AA
        # LAX (zp),Y
        0xA9, 0x90, 0x85, 0xA0, # LDA #$90; STA $A0
        0xA9, 0x00, 0x85, 0xA1, # LDA #$00; STA $A1
        0xA0, 0x00,             # LDY #$00
        0xB3, 0xA0,             # LAX ($A0),Y -> reads $0090 = $AA
        # Done — NOP forever.
    ]
    return prog


def m8a_rmw_combos():
    """Exercises DCP / ISC / SLO / RLA / SRE / RRA across modes."""
    prog = [
        # ---- DCP zp ($C7) ----
        # mem[$80] = $03; A = $03 → CMP after DEC → mem=$02, Z=0 C=1 N=0
        0xA9, 0x03, 0x85, 0x80,         # LDA #$03; STA $80
        0xA9, 0x03,                     # LDA #$03
        0xC7, 0x80,                     # DCP $80   → mem=$02, CMP A($03) vs $02
        # ---- ISC zp ($E7) ----
        # mem[$81] = $04; A=$05; C=0; SBC → A = A - new_M - !C = 5 - 5 - 1 = -1
        0xA9, 0x04, 0x85, 0x81,
        0x18,                           # CLC
        0xA9, 0x05,                     # LDA #$05
        0xE7, 0x81,                     # ISC $81   → mem=$05, A = 5-5-1 = $FF
        # ---- SLO zp ($07) ----
        # mem[$82] = $40; A=$01; SLO → mem = $80 (shift), A = A | $80 = $81
        0xA9, 0x40, 0x85, 0x82,
        0xA9, 0x01,
        0x07, 0x82,                     # SLO $82
        # ---- RLA zp ($27) ----
        # mem[$83] = $C0; C=0; A=$0F; RLA → mem ROL = $80 (C=1), A = A & $80 = 0
        0xA9, 0xC0, 0x85, 0x83,
        0x18,                           # CLC
        0xA9, 0x0F,
        0x27, 0x83,                     # RLA $83
        # ---- SRE zp ($47) ----
        # mem[$84] = $03; A=$05; SRE → mem LSR = $01 (C=1), A = A ^ $01 = $04
        0xA9, 0x03, 0x85, 0x84,
        0xA9, 0x05,
        0x47, 0x84,                     # SRE $84
        # ---- RRA zp ($67) ----
        # mem[$85] = $03; C=0; A=$05; RRA → mem ROR = $01 (C=1), A = 5 + 1 + 1 = $07
        0xA9, 0x03, 0x85, 0x85,
        0x18,
        0xA9, 0x05,
        0x67, 0x85,                     # RRA $85
        # ---- DCP abs,X ($DF) — exercise indexed mode ----
        0xA9, 0x10, 0x8D, 0x00, 0x02,   # STA $0200 (mem = $10)
        0xA2, 0x00,
        0xA9, 0x10,
        0xDF, 0x00, 0x02,               # DCP $0200,X  → mem=$0F, CMP A($10) vs $0F → C=1
        # ---- Immediate undoc combos ----
        # ANC #$F0  -> A = $10 & $F0 = $10. wait, A was $10 from previous LDA.
        # Use a fresh LDA. ANC: A = A & imm, C = bit 7 of result.
        0xA9, 0xFF, 0x0B, 0x80,         # LDA #$FF; ANC #$80  → A=$80, C=1, N=1
        0xA9, 0xFF, 0x2B, 0x0F,         # LDA #$FF; ANC #$0F  → A=$0F, C=0, N=0
        # ALR #$0F  -> A = ($FF & $0F) >> 1 = $07; C = $0F & 1 = 1
        0xA9, 0xFF, 0x4B, 0x0F,         # LDA #$FF; ALR #$0F  → A=$07, C=1
        # ARR #$0F  -> ROR((A & 0F)). A=$0F & $0F = $0F. {C_in, $0F >> 1}.
        # If C_in was 1 (from ALR above): result = {1, $07} = $87. C = res[6] = 0.
        0x6B, 0x0F,                     # ARR #$0F
        # AXS: X = (A & X) - imm. A=$87, X=$10 (still from earlier).
        # (A & X) = $87 & $10 = $00. $00 - $05 = $FB (borrow). C=0 (borrow).
        0xCB, 0x05,                     # AXS #$05
        # End: infinite loop so PC doesn't walk into the data zone we just
        # wrote (would land on a KIL opcode like $02). 4C XX XX = JMP $XXXX.
    ]
    # Compute the JMP target (the JMP itself) and append.
    jmp_addr = len(prog)
    prog += [0x4C, jmp_addr & 0xFF, (jmp_addr >> 8) & 0xFF]
    return prog


def m8b_unstable():
    """Exercises the unstable / magic-constant undocumented opcodes
    (XAA, LAS, TAS, SHX, SHY, AHX) using inputs where the result is
    deterministic regardless of the silicon's analog state.

    - XAA with X=0 or imm=0 yields A=0 regardless of the magic constant.
    - SHX/SHY/AHX/TAS without page crossing: store value = reg & (hi+1),
      target address = base + index.
    - LAS: A=X=S = mem & S, well-defined.
    """
    prog = [
        # ---- XAA with X=0  (A=0 regardless of constant) ----
        0xA9, 0xFF,             # LDA #$FF
        0xA2, 0x00,             # LDX #$00
        0x8B, 0xAA,             # XAA #$AA  → A = (A|const) & 0 & ... = 0
        # ---- XAA with imm=0  (A=0) ----
        0xA9, 0x33,             # LDA #$33
        0xA2, 0xFF,             # LDX #$FF
        0x8B, 0x00,             # XAA #$00  → A = ... & 0 = 0
        # ---- SHX abs,Y  no page cross ----
        # Base = $0200, Y=$10, target = $0210. hi+1 = $03. X = $0F. Store $0F&$03 = $03.
        0xA0, 0x10,             # LDY #$10
        0xA2, 0x0F,             # LDX #$0F
        0x9E, 0x00, 0x02,       # SHX $0200,Y
        # ---- SHY abs,X  no page cross ----
        # Base = $0300, X=$08, target = $0308. hi+1 = $04. Y = $05. Store $05&$04 = $04.
        0xA2, 0x08,             # LDX #$08
        0xA0, 0x05,             # LDY #$05
        0x9C, 0x00, 0x03,       # SHY $0300,X
        # ---- AHX abs,Y  no page cross ----
        # Base = $0400, Y=$12, target = $0412. hi+1 = $05. A=$F0, X=$77.
        # Store A&X&(hi+1) = $F0 & $77 & $05 = $00.
        0xA9, 0xF0, 0xA2, 0x77, 0xA0, 0x12,
        0x9F, 0x00, 0x04,       # AHX $0400,Y
        # ---- TAS abs,Y  no page cross ----
        # A=$33, X=$F0, Y=$08, base=$0500, target=$0508. hi+1=$06.
        # S = A&X = $30. Store S&(hi+1) = $30 & $06 = $00.
        0xA9, 0x33, 0xA2, 0xF0, 0xA0, 0x08,
        0x9B, 0x00, 0x05,       # TAS $0500,Y
        # ---- LAS abs,Y ----
        # First prime mem[$0610] with $5A via STA.
        0xA9, 0x5A, 0xA0, 0x10, 0x99, 0x00, 0x06,  # LDA #$5A; LDY #$10; STA $0600,Y
        # Now LAS reads $0610. Need to set S first.
        0xA2, 0xFF, 0x9A,       # LDX #$FF; TXS  → S=$FF
        0xA0, 0x10,             # LDY #$10
        0xBB, 0x00, 0x06,       # LAS $0600,Y  → A=X=S = $5A & $FF = $5A
    ]
    # Self-loop tail so PC doesn't walk into the wrote data.
    jmp_addr = len(prog)
    prog += [0x4C, jmp_addr & 0xFF, (jmp_addr >> 8) & 0xFF]
    return prog


TESTS = {
    "nop_loop": (m3_nop, 0x0000),
    "m4_loadstore": (m4_loadstore, 0x0000),
    "m5_alu": (m5_alu, 0x0000),
    "m6_stack_subroutines": (m6_stack_subroutines, None),
    "m7_branches": (m7_branches, None),
    "m8_undoc": (m8_undoc, 0x0000),
    "m8a_rmw_combos": (m8a_rmw_combos, 0x0000),
    "m8b_unstable": (m8b_unstable, 0x0000),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", choices=sorted(TESTS), help="Test program to build")
    ap.add_argument("--out", help="Output .bin path", required=True)
    args = ap.parse_args()

    builder, load_addr = TESTS[args.name]
    prog = builder()
    if load_addr is None:
        # Builder returned a complete 64KB image (multi-block layout).
        bin_ = prog
    else:
        bin_ = make_bin(prog)
    with open(args.out, "wb") as f:
        f.write(bin_)
    if load_addr is None:
        sys.stderr.write("wrote %s (%d bytes, multi-block layout)\n"
                         % (args.out, len(bin_)))
    else:
        sys.stderr.write("wrote %s (%d bytes, %d program bytes)\n"
                         % (args.out, len(bin_), len(prog)))


if __name__ == "__main__":
    main()
