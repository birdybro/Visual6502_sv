# DESIGN.md

Architectural decisions for the SystemVerilog 6502 core, and the places where the
RTL deliberately diverges in **structure** from the Visual6502 transistor model
while preserving its **observable behavior**.

## Guiding principle

Visual6502 is a switch-level simulator over the actual silicon netlist. It is the
oracle, not the implementation. The RTL is a clean, synchronous CPU that must
match Visual6502 cycle-by-cycle on externally visible signals (address bus, data
bus, R/W, sync, interrupts) and on architecturally visible state at the
appropriate cycle boundaries (A, X, Y, S, P, PC). Internal microarchitecture is
free to differ wherever doing so yields cleaner, more synthesizable RTL.

## Clocking model

The real 6502 is a **two-phase** part driven by an external phi0 (`clk0` in
Visual6502 nodenames). One bus cycle = phi1 low + phi2 high; address is set up
during phi1 and the read/write of the data bus happens around phi2. Visual6502
models this with `halfStep()` toggling `clk0`; two half-steps = one bus cycle.

For RTL we use a **single-edge synchronous design**:

- `clk` is a free-running clock.
- One `clk` rising edge advances the core by exactly one bus cycle (one T-state).
- All architectural state lives in `always_ff @(posedge clk)` registers.
- The address bus and R/W are combinational from current state, mirroring how
  the 6502 sets up the address during phi1; the testbench presents `data_in`
  before the next rising edge, mirroring the data being valid by end of phi2.

This deliberately collapses the two phases. To compare against Visual6502 we
sample the reference at a consistent phi boundary (typically end of phi2, when
`clk0` falls in the JS reference) and align the RTL's per-cycle records to it.
A future phase-accurate mode can be added by promoting `clk` to phi0 and adding
internal phi1/phi2 fan-out, but it is not required for cycle-level equivalence.

Trade-off: this loses sub-cycle visibility into things like phi1-vs-phi2 address
stability. It does not lose anything observable at the CPU pins between cycles,
which is what every bus master and test ROM cares about.

## Reset

The 6502 uses 7 cycles after reset deassertion to fetch the reset vector from
$FFFC/$FFFD and start fetching. The RTL replicates the cycle count exactly,
including the dummy reads, by entering a dedicated reset microsequence on the
first cycle after `reset_n` is deasserted. The Visual6502 trace of the reset
sequence is the reference; see `tests/traces/reset.tsv`.

## Decode

Visual6502's decoder is a PLA: `transdefs.js` includes ~130 product terms whose
gates are driven by IR and the timing state, with outputs named `op-XXX`. We
will **not** instantiate a literal PLA. Instead:

- `mos6502_decode` is a `case (ir)` returning a struct of control signals
  (addressing mode, ALU op, register source/dest, flag-update mask, etc.).
- `docs/visual6502_mapping.md` records which PLA outputs map to which decode
  bits, so the equivalence can be argued from the reference.
- For undocumented opcodes that survive in the real silicon by virtue of
  partial PLA matches, the RTL must reproduce the behavior observed by
  Visual6502, not invent its own — these go in M8.

## ALU

The Visual6502 ALU is a transistor-level adder/logic unit with separate input
holding registers (alua/alub) and a decimal-mode correction stage. The RTL ALU
will be a combinational block computing all of {ADC, SBC, AND, ORA, EOR, ASL,
LSR, ROL, ROR, INC, DEC, CMP, BIT} plus flags. Decimal-mode correction matches
the well-documented 6502 semantics, with the **invalid-BCD edge cases**
specifically verified against Visual6502 (the real chip has known
non-intuitive N/Z behavior in decimal mode that 65C02 cleans up; we match the
NMOS 6502).

## Address generation

A dedicated `mos6502_addrgen` produces the bus address per microcycle. All
quirks live here:

- Zero-page indexed wraps in 8 bits.
- Absolute indexed crosses pages — when the low-byte add carries, an extra
  read cycle is taken at the un-fixed-up address (the "dummy" cycle); reads
  may skip it when there is no page cross, writes always take it.
- Indirect indexed (`(zp),Y`) same dummy-cycle behavior.
- Branch target page crossing adds a cycle.
- **JMP ($xxFF) page-wrap bug**: the high byte is fetched from $xx00, not
  $(xx+1)00. Explicitly reproduced and tested.

## Interrupts

- IRQ/NMI/BRK/reset share a 7-cycle entry sequence with small differences in
  which writes are suppressed (reset) and which vector is fetched.
- NMI is edge-sensitive (latch on falling edge of `nmi_n`), IRQ is
  level-sensitive and masked by `I`. The latch lives in `mos6502_core` and is
  cleared when the NMI is taken.
- The "B flag" trick: the value pushed to the stack reflects whether the entry
  was a software (BRK) or hardware (IRQ/NMI) interrupt — bit 4 is set on push
  for BRK/PHP, cleared for IRQ/NMI. Bit 5 is always set when pushed.
- Reset suppresses the three stack pushes (they happen as reads with R/W high
  in the real chip; we reproduce that on the bus).

## Pins / interface

The top-level interface (`rtl/cpu/mos6502_core.sv`) follows the specification:

```
clk, reset_n, irq_n, nmi_n, ready, so_n          inputs
address[15:0], data_out[7:0], rw, sync            outputs
data_in[7:0]                                      input
```

Notes:
- `ready` (RDY) freezes the core on reads (per real 6502) — writes complete
  before honoring RDY. Implemented by gating the state-machine advance.
- `so_n` (SO, set-overflow input) sets the V flag asynchronously to instruction
  flow but synchronously to `clk` in our implementation; documented quirk.
- The real chip has separate `phi1out`/`phi2out` pins (Visual6502
  `clk1out`/`clk2out`). They are omitted from the synchronous interface; if a
  phase-accurate wrapper is needed later (e.g. for a MiSTer core that drives
  a real bus), it will be added in `rtl/common/`.

## What is intentionally NOT in the RTL

- Pass-transistor / switch-level modeling. No `tri`, no internal tri-states.
- Dynamic / precharge logic. All storage is in flip-flops.
- Bus contention modeling beyond what the pins expose.
- Visible PLA. Decode is a clean case statement.

These are listed so future readers do not "fix" their absence.

## Verification strategy

See `README.md` for the workflow. The short version: every implemented
opcode/cycle must have a trace test that matches Visual6502 byte-for-byte on
the externally visible signals over the relevant cycles. New behaviors land
**with** their reference trace.
