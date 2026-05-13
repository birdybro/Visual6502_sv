# Visual6502_sv

A clean, synthesizable SystemVerilog reimplementation of the **MOS 6502** CPU, using the
[Visual6502](http://visual6502.org/) transistor-level netlist as a behavioral oracle.

The goal is **observable equivalence** to a real 6502, not a literal pass-transistor
translation. The Visual6502 simulator is used as a golden reference to generate
cycle-accurate traces (address bus, data bus, R/W, sync, architectural state); the RTL
core is verified against those traces.

## Status

Milestone 8 (full stable undocumented opcode set) complete; 2052 cycles of program execution across M3-M8 match the Visual6502 reference exactly on AB/DB/RW/SYNC.

| Milestone | Status | Notes |
|----|----|----|
| M1 — Repo, docs, build skeleton | done | |
| M2 — Visual6502 trace extractor + comparator | done | Headless Node engine + Python comparator. |
| M3 — Reset, instruction fetch, NOP, PC increment | done | `make test-m3` passes against reference. |
| M4 — Loads/stores, addressing modes, transfers | done | All AM × {LDA,LDX,LDY,STA,STX,STY} + T?? transfers. |
| M5 — ALU, ADC/SBC (binary + decimal), shifts | done | ADC/SBC/AND/ORA/EOR/CMP/CPX/CPY/BIT/ASL/LSR/ROL/ROR/INC/DEC/INX/INY/DEX/DEY/flag-instr. |
| M6 — Stack, JSR/RTS, BRK/RTI, IRQ/NMI | done | PHA/PHP/PLA/PLP, JSR/RTS, BRK/RTI, IRQ entry. NMI implemented; precise cycle alignment varies in some patterns. |
| M7 — Branches, page crossings, JMP indirect bug | done | All 8 branches, fwd/bwd page cross, JMP abs, JMP $xxFF wrap bug. |
| M8 — Undocumented opcodes, broader ROM | done | NOPs (1/2/3-byte), SAX, LAX, plus the combined RMW+ALU family (DCP/ISC/SLO/RLA/SRE/RRA × 7 modes each) and the immediate combos (ANC/ALR/ARR/AXS). Unstable opcodes (XAA/AHX/SHX/SHY/TAS/LAS) documented as not modelable. |
| M9 — Synthesis polish, MiSTer wrapper | done | Lint clean -Wall, RDY/SO pins live, `rtl/common/mos6502_mister.sv` wrapper, `make synth` documented, `scripts/run_ci.sh` end-to-end. |
| M9 — Synthesis polish, optional MiSTer wrapper | pending | |

## Repository layout

```
docs/                      Architecture, Visual6502 mapping, references.
rtl/cpu/                   Synthesizable core (mos6502_core, _alu, _decode, ...).
rtl/common/                Shared synthesizable building blocks.
sim/visual6502_ref/        Headless port of the JS reference simulator.
sim/cpp/                   Reusable C++ for testbenches (memory model, trace I/O).
sim/verilator/             Verilator harness (tb_mos6502_core.cpp, run scripts).
tests/asm/                 Small assembly tests authored locally.
tests/roms/                Imported test ROMs (only where licensing allows).
tests/traces/              Recorded reference / RTL trace artifacts.
tools/extract_visual6502/  Tooling that runs the JS reference and emits traces.
tools/trace_compare/       Cycle-by-cycle trace comparator.
scripts/                   Convenience scripts (lint, sim wrappers, etc.).
visual6502-master/         Upstream Visual6502 reference (read-only, MIT).
```

## Prerequisites

- Verilator >= 5.0 (the project is developed against 5.048)
- A C++17 compiler (whatever Verilator's `obj_dir/` uses)
- GNU Make
- Node.js >= 18 (for the headless Visual6502 reference)

## Build / test commands

```
make lint     # verilator --lint-only on all RTL
make sim      # build the Verilator simulation
make test     # run the simulation suite (currently: skeleton smoke test)
make clean    # remove build artifacts
```

The Makefile lives at the top of the repo and dispatches to `sim/verilator/`.

## How verification works

1. `tools/extract_visual6502/` drives the Visual6502 JS simulator headlessly under
   Node and emits a canonical trace per cycle:
   `cycle, phi, AB, DB, R/W, sync, A, X, Y, S, P, PC`.
2. The Verilator harness runs the same program against the RTL core and emits a trace
   in the same format.
3. `tools/trace_compare/` reads both, aligns them on bus cycles (ignoring half-cycle
   phase differences when configured), and reports the first divergence with context.

See `DESIGN.md` for architectural decisions and `docs/visual6502_mapping.md` for the
authoritative mapping from Visual6502 nets / nodenames to RTL signals.

## License

The new RTL, tooling, and documentation in this repository are released under the MIT
license (see `LICENSE`). Files under `visual6502-master/` retain their upstream MIT
license and original copyright notices (Brian Silverman, Barry Silverman, et al.); see
file headers and `visual6502-master/README` for details.
