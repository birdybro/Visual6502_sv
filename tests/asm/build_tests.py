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


TESTS = {
    "nop_loop": (m3_nop, 0x0000),
    "m4_loadstore": (m4_loadstore, 0x0000),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", choices=sorted(TESTS), help="Test program to build")
    ap.add_argument("--out", help="Output .bin path", required=True)
    args = ap.parse_args()

    builder, load_addr = TESTS[args.name]
    prog = builder()
    bin_ = make_bin(prog)
    # We store the full 64KB image. The harness loads at +load_addr=0x0000.
    with open(args.out, "wb") as f:
        f.write(bin_)
    sys.stderr.write("wrote %s (%d bytes, %d program bytes)\n"
                     % (args.out, len(bin_), len(prog)))


if __name__ == "__main__":
    main()
