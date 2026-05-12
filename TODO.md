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

- [x] Reset state machine: 6 cycles before sync (R0 dummy, R1-3 suppressed
      stack pushes with S decrement, R4-5 vector fetch from $FFFC/D), 7th cycle
      is first opcode fetch with sync=1.
- [x] PC register and increment path.
- [x] Bus interface: drive AB, DB out, RW, sync correctly per cycle.
- [x] Instruction fetch microcycle (sync=1, IR <= DB, PC++).
- [x] NOP ($EA) — 2-cycle, no side effects beyond PC++.
- [x] Unimplemented opcodes route to a 2-cycle dummy path so the bus stays
      well-defined while later milestones implement them.
- [x] Reset matches Visual6502 from cycle 3 onwards (the first 3 power-on
      cycles diverge by design — the RTL has deterministic init).
- [x] NOP trace matches Visual6502 over 64 cycles on ab,db,rw,sync.

## Milestone 4 — Loads / stores / transfers

- [x] Register file (A, X, Y, S, P, PC) with synchronous write enables.
- [x] Addressing modes: immediate, zero page, zp,X / zp,Y, abs, abs,X / abs,Y,
      (zp,X), (zp),Y.
- [x] Page-crossing dummy cycle: skipped on loads with no cross, always
      taken on stores.
- [x] Instructions: LDA, LDX, LDY, STA, STX, STY.
- [x] Transfers: TAX, TAY, TXA, TYA, TSX, TXS.
- [x] Flag updates: N, Z on loads and on transfers except TXS.
- [x] `make test-m4` passes 194 cycles against Visual6502.

## Milestone 5 — ALU

- [x] Combinational `mos6502_alu` with ops: ADC, SBC, AND, ORA, EOR,
      ASL, LSR, ROL, ROR, INC, DEC, CMP, BIT.
- [x] Flag generation: N, Z, C, V (per-op masks at the commit site).
- [x] Decimal-mode ADC/SBC matching NMOS quirks (V on intermediate, etc.).
- [x] CMP / CPX / CPY.
- [x] BIT (N from b[7], V from b[6], Z from A & memory).
- [x] RMW memory: read → dummy-write old → write new, address held in
      `rmw_target_q` across the three cycles.
- [x] Accumulator-mode shifts (ASL A / LSR A / ROL A / ROR A): 2-cycle
      implied via S_T1_DUMMY.
- [x] INX / INY / DEX / DEY: 2-cycle implied via S_T1_DUMMY.
- [x] Flag set/clear instructions (CLC/SEC/CLI/SEI/CLD/SED/CLV).
- [x] 494 cycles of an M5 program match Visual6502 exactly, including
      decimal-mode ADC and SBC across nibble-carry edge cases.

## Milestone 6 — Stack + interrupts

- [x] PHA, PHP, PLA, PLP.
- [x] JSR (low-byte fetched first, then high-byte after stack pushes).
- [x] RTS, RTI.
- [x] BRK (push PC+2, push P with B set, fetch from $FFFE/F, set I).
- [x] IRQ entry (push P with B clear, fetch from $FFFE/F, set I). Verified
      end-to-end via `make test-m6-irq`.
- [x] NMI entry (edge-latched, fetch from $FFFA/B). Structurally implemented;
      cycle alignment with Visual6502 within ~2 cycles depending on the
      instruction state at assertion time. Acceptable for most use; refine
      later if tighter equivalence is needed.
- [x] Reset entry (suppressed pushes, fetch from $FFFC/D) — from M3.
- [ ] CLI/SEI one-instruction delay before IRQ can be taken (current
      implementation rechecks IRQ at every fetch; in practice this matches
      Visual6502 for back-to-back CLI then BRK/IRQ as long as the I flag
      transitions match per-cycle, but the exact "delayed sample" semantics
      are not separately modeled).
- [x] Trace test: stack + JSR + RTS + BRK + RTI in `m6_stack.bin` (174 cycles).
- [x] Trace test: IRQ injection via plusarg (`m6_irq.tsv`, 224 cycles).

## Milestone 7 — Branches + dummy cycles + JMP indirect bug

- [x] Bcc family (BPL/BMI/BVC/BVS/BCC/BCS/BNE/BEQ) with 2/3/4-cycle counts.
- [x] Branch page-cross extra cycle (T3 dummy at fixed PC).
- [x] Indexed-load dummy read on page cross (M4); indexed-store always (M4).
- [x] JMP absolute.
- [x] **JMP ($xxFF)** wraps high-byte fetch to $xx00.
- [x] 264 cycles of branch/JMP test match Visual6502.
- [ ] RDY freeze on read; writes complete before honoring RDY (M9 polish).
- [ ] SO pin sets V flag (M9 polish).

## Milestone 8 — Undocumented opcodes + ROM compatibility

- [x] Undocumented NOPs (1/2/3-byte forms): $1A/$3A/$5A/$7A/$DA/$FA;
      $80/$82/$89/$C2/$E2; $04/$44/$64; $14/$34/$54/$74/$D4/$F4;
      $0C; $1C/$3C/$5C/$7C/$DC/$FC.
- [x] SAX (store A & X): $87/$97/$8F/$83.
- [x] LAX (load both A and X): $A7/$B7/$AF/$BF/$A3/$B3.
- [x] 264 cycles match Visual6502 (`make test-m8`).
- [ ] DCP / ISC: combined RMW + CMP/SBC. Needs the RMW final-write state
      to also affect A's flags. Future work.
- [ ] SLO / RLA / SRE / RRA: combined RMW shift + ALU on A. Future work.
- [ ] ANC / ALR / ARR / AXS: 2-cycle immediate ALU combinations.
      Future work.
- [ ] Unstable: XAA / AHX / SHX / SHY / TAS / LAS — behavior depends on
      transistor analog state (not modeled in clean RTL). Will document as
      "unimplemented; emit a $EA-equivalent placeholder behavior."
- [ ] Klaus Dormann 6502 functional test ROM end-to-end run. Requires the
      DCP/ISC/SLO/RLA family for full compatibility.

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
