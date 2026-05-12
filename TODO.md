# TODO

Living checklist. Update as work progresses. Items marked `[x]` are done,
`[ ]` are pending, `[~]` are partially done.

## Milestone 1 — Foundation

- [x] Audit Visual6502 reference material; document data formats.
- [x] Create directory skeleton.
- [x] Write `README.md`, `DESIGN.md`, `TODO.md`, `docs/visual6502_mapping.md`.
- [x] Skeleton `rtl/cpu/mos6502_core.sv` matching the spec interface.
- [x] Minimal Verilator harness (`sim/verilator/tb_mos6502_core.cpp`).
- [x] Top-level `Makefile` with `lint`, `sim`, `test`, `clean`.
- [x] `make lint` and `make sim` pass on a fresh checkout.

## Milestone 2 — Reference trace extraction + comparator

- [x] Headless port of Visual6502 under Node (`sim/visual6502_ref/visual6502_headless.js`).
- [x] No DOM dependencies; data files loaded via `vm.runInContext`.
- [x] `tools/extract_visual6502/run.js` accepts `--load-addr`, `--reset-vec`,
      `--cycles`, `--output`, `--include-reset`, `--skip-halfsteps`.
- [x] Canonical trace TSV header: `cycle phi0 ab db rw sync a x y s p pc ir`.
- [x] `tools/trace_compare/compare.py` aligns by row, reports first mismatch
      with ±N context, supports `--skip`, `--max-cycles`, `--fields`.
- [x] Baseline reset trace `tests/traces/reset_brk.tsv` (cycles 0-23 from reset).
- [x] Baseline NOP-loop trace `tests/traces/nop_loop.tsv`.
- [x] Makefile targets `trace-ref-reset`, `trace-ref-nop`, `trace-self-check`.
- [ ] Verilator harness will emit the same trace format from a `+trace=path` plusarg
      (deferred to M3 where the RTL produces meaningful bus activity).

## Milestone 3 — Reset + fetch + NOP

- [ ] Reset state machine (7 cycles, dummy reads, vector fetch from $FFFC/D).
- [ ] PC register and increment path.
- [ ] Bus interface: drive AB, DB out, RW, sync correctly per cycle.
- [ ] Instruction fetch microcycle.
- [ ] NOP ($EA) — 2-cycle, no side effects beyond PC++.
- [ ] Reset trace matches Visual6502.
- [ ] NOP trace matches Visual6502 over 100+ cycles.

## Milestone 4 — Loads / stores / transfers

- [ ] Register file (A, X, Y, S, P, PC) with appropriate write enables.
- [ ] Addressing modes: immediate, zero page, zp,X / zp,Y, abs, abs,X / abs,Y,
      (zp,X), (zp),Y.
- [ ] Instructions: LDA, LDX, LDY, STA, STX, STY.
- [ ] Transfers: TAX, TAY, TXA, TYA, TSX, TXS.
- [ ] Flag updates: N, Z on loads/transfers.
- [ ] Trace tests for each mode × each instruction.

## Milestone 5 — ALU

- [ ] Combinational `mos6502_alu` with op enum: ADC, SBC, AND, ORA, EOR,
      ASL, LSR, ROL, ROR, INC, DEC, CMP, BIT.
- [ ] Flag generation: N, Z, C, V (per-op masks).
- [ ] Decimal-mode ADC/SBC matching NMOS 6502 quirks.
- [ ] CMP / CPX / CPY.
- [ ] BIT (N from bit 7, V from bit 6, Z from AND result).
- [ ] Trace tests per op, including BCD edge cases ($99+$01, $00-$01, etc.).

## Milestone 6 — Stack + interrupts

- [ ] PHA, PHP, PLA, PLP.
- [ ] JSR (note: low-byte fetched first, then high-byte after stack pushes).
- [ ] RTS, RTI.
- [ ] BRK (push PC+2, push P with B set, fetch from $FFFE/F, set I).
- [ ] IRQ entry (push P with B clear, fetch from $FFFE/F, set I).
- [ ] NMI entry (edge-latched, fetch from $FFFA/B).
- [ ] Reset entry (suppressed pushes, fetch from $FFFC/D).
- [ ] CLI/SEI timing (one-instruction delay before IRQ can be taken).
- [ ] Trace tests for each path including IRQ-during-instruction.

## Milestone 7 — Branches + dummy cycles + JMP indirect bug

- [ ] Bcc family with correct taken/not-taken cycle counts.
- [ ] Branch page-cross extra cycle.
- [ ] Indexed-load dummy read on page cross; indexed-store always.
- [ ] JMP absolute.
- [ ] **JMP ($xxFF)** wraps high-byte fetch to $xx00.
- [ ] RDY freeze on read; writes complete before honoring RDY.
- [ ] SO pin sets V flag.

## Milestone 8 — Undocumented opcodes + ROM compatibility

- [ ] Survey: which undocumented opcodes are stable on NMOS 6502 per the
      visual6502 net data + Klaus Dormann tests.
- [ ] Implement the deterministic ones (SAX, LAX, DCP, ISC, SLO, RLA, SRE, RRA,
      ANC, ALR, ARR, AXS, XAA, AHX, SHX, SHY, TAS, LAS — last few are unstable).
- [ ] Mark unstable ones (e.g. XAA) with the documented "magic constant" behavior.
- [ ] Run Klaus Dormann functional test ROM to completion.

## Milestone 9 — Synthesis polish

- [ ] `make synth` target (Yosys/nextpnr or a vendor flow) producing timing data.
- [ ] FPGA-friendly cleanup: ensure no inferred latches, reset polarity sane,
      one clock domain.
- [ ] Optional MiSTer-style wrapper exposing phi1out/phi2out and matching the
      MiSTer cpu_6502 interface (see `rtl/common/mos6502_mister.sv`).
- [ ] Fmax target on Cyclone V / Artix-7: TBD.

## Cross-cutting

- [ ] Lint clean under Verilator `-Wall`.
- [ ] CI script that runs lint + sim suite.
- [ ] Every commit that adds behavior also adds at least one trace test.
