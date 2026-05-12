# Visual6502 → SystemVerilog mapping

This document is the authoritative reference for how the Visual6502 reference
simulator's data and signal names relate to the SystemVerilog implementation.
When in doubt, **read the JS files directly** — they are the spec.

## Provenance

All files under `visual6502-master/` are an unmodified snapshot of the
[visual6502 repository](https://github.com/trebonian/visual6502), MIT-licensed,
© Brian Silverman, Barry Silverman, Ed Spittles, Achim Breidenbach, Segher
Boessenkool. License text is preserved in each file's header.

The data describes a **6502 revision D** die. There are revision-specific
behaviors (notably in some undocumented opcodes); when this matters, the RTL
matches revision D and notes it.

## Data files

### `segdefs.js` (~1 MB)

Polygon geometry per node, used by the JS sim only for drawing the layout.
**Not used** by the SV port or the trace extractor. Each entry is
`[node, pullup_or_pulldown, color, x0, y0, x1, y1, ...]`.

### `transdefs.js` (~265 KB, 3512 lines, ~3510 transistors)

The transistor netlist. Each row:

```
['tNNN', gate_node, c1_node, c2_node, bbox, geometry...]
```

This is the **authoritative netlist** of the chip. We do not implement it
literally; we use it as ground truth when an architectural question cannot be
answered from documentation alone (e.g. "what does this PLA output gate
actually drive?").

### `nodenames.js` (~950 lines)

Symbolic names → node numbers. The named subset is small (~few hundred); the
chip has ~1700 nodes total, most unnamed. Names we rely on:

**Pads (CPU pins):**
| Name in JS | Direction | Meaning | RTL signal |
|---|---|---|---|
| `res` | in | Reset, active low | `reset_n` |
| `clk0` | in | Phi0 clock input | `clk` (collapsed phases — see DESIGN.md) |
| `rdy` | in | Ready, active high | `ready` |
| `irq` | in | IRQ, active low | `irq_n` |
| `nmi` | in | NMI, active low | `nmi_n` |
| `so` | in | Set Overflow, active low edge | `so_n` |
| `ab0..ab15` | out | Address bus | `address[15:0]` |
| `db0..db7` | bidi | Data bus | `data_in`/`data_out` + `rw` |
| `rw` | out | Read (1) / Write (0) | `rw` |
| `sync` | out | Instruction fetch indicator | `sync` |
| `clk1out`, `clk2out` | out | Phi1/Phi2 outputs | *omitted from sync interface* |
| `vcc`, `vss` | power | | not modeled |

**Architectural registers** (each is 8 stored bits, named e.g. `a0..a7`):
- `a0..a7` — accumulator
- `x0..x7` — X index
- `y0..y7` — Y index
- `s0..s7` — stack pointer
- `pcl0..pcl7`, `pch0..pch7` — PC low / high (the JS calls the first storage
  node "pcl", and a separate pre-incrementer node series "pclp" / "pchp").
  In the RTL we have a single 16-bit PC; the pre-increment register is an
  internal microarchitectural detail of the silicon that need not be modeled.
- `p0..p7` — status register bits. **Note**: `p4` exists as a node but is not
  a real storage bit; `p5` is `-1` (no node). The "B flag" bit 4 and the unused
  bit 5 are generated on push, not stored. Bits: `p0=C, p1=Z, p2=I, p3=D, p6=V, p7=N`.
- `ir0..ir7` — instruction register (raw and inverted `notir0..7`).

**Internal control / timing** (the RTL does not have to expose these, but the
docs/decoder reference them):
- `clock1`, `clock2`, `t2..t5` — the 6 timing-state nodes that drive the PLA.
  Visual6502 documents these in `allTCStates()`. They are **inverted-one-hot**
  (active low). The RTL replaces this with an FSM enum `t_state_e`.
- `VEC0`, `VEC1` — interrupt vector phase selectors.
- `cp1` — internal phase 1 (used by `chipStatus` to pretty-print Φ1/Φ2).

**Convention**: name patterns like `aN`, `xN`, `pclN` are arrays of 8 nodes;
`readBits('a', 8)` in `macros.js` reads them as an unsigned byte.

## Simulator entry points

These are what the trace extractor will drive:

| JS function | What it does | Use |
|---|---|---|
| `initChip()` | Power-on reset: float all nodes, set vss/vcc, recalc, hold reset, run 8 clk0 toggles, release reset, run 18 halfsteps. | One-time setup before extraction. |
| `halfStep()` | Toggle `clk0` once. On rising edge, perform bus read (drive `db` from memory if `rw`==1); on falling edge, perform bus write (sample `db` into memory if `rw`==0). Calls `clockTriggers[cycle+1]` eval hook. | The unit of simulation; two halfsteps per bus cycle. |
| `step()` | Records the chip state into `trace[cycle]`, calls `halfStep`, increments `cycle`. | Convenience wrapper. |
| `mWrite(a,d)`, `mRead(a)` | The host memory model — a sparse 64K array. | Load test programs / inspect writes. |
| `readBits(name,n)` | Read a named n-bit bus as an unsigned integer. | Sampling regs/buses for the trace. |
| `readAddressBus()`, `readDataBus()`, `readA/X/Y/SP/P/PC()` | Convenience readers. | Trace fields. |

### Cycle semantics

The JS code's `cycle` variable counts **half-cycles**. One bus cycle = 2
halfsteps = one full phi0 period. The trace extractor should emit one record
per bus cycle, sampled at a consistent phase boundary (we use end-of-phi2, i.e.
right after the falling edge of `clk0`, matching when `chipStatus` is usually
called). The RTL emits one record per `clk` rising edge.

## DOM dependencies in the JS reference

`chipsim.js` itself is clean. `wires.js`, `macros.js`, and the other JS files
reach into `document.getElementById(...)` for canvas/log UI. For headless
extraction, the plan is:

1. Load only `segdefs.js`, `transdefs.js`, `nodenames.js` for data.
2. Load `chipsim.js` for the engine.
3. Copy and trim the **netlist-setup** parts of `wires.js` (`setupNodes`,
   `setupTransistors`) — drop all the canvas/draw functions.
4. Copy the **simulation control** parts of `macros.js` (`halfStep`,
   `handleBusRead`, `handleBusWrite`, `mRead`, `mWrite`, `readBits`, `initChip`'s
   logic but without `refresh`/`chipStatus` calls) — drop the UI/logbox/cell
   functions.
5. Stub `chipStatus`/`refresh`/`updateLogList`/`selectCell`/`setStatus` as no-ops.

This headless slice lives at `sim/visual6502_ref/` and is the only place that
should `require` files from `visual6502-master/`.

## PLA outputs

Visual6502 names its PLA outputs `op-XXX` (and a few `x-op-XXX` / `xx-op-XXX`
prefixed variants). `busToString('plaOutputs')` returns all active ones. A
useful tactic when debugging a decode mismatch:

1. Run the JS reference for the failing instruction.
2. Snapshot the active `op-*` set per cycle.
3. Compare to what the RTL decoder believes is active for the same `ir` +
   timing state.

The exhaustive list of PLA output names is not enumerated here — it is in
`nodenames.js` and `transdefs.js`, and grepping for `op-` is the right move
when needed.

## License and redistribution

Any code in `tools/extract_visual6502/` that loads or evaluates files from
`visual6502-master/` must preserve those files' copyright headers and not
modify them in place. Derivative trace data captured from the reference (under
`tests/traces/`) is considered output, not a derived work of the JS code, and
is licensed alongside this project. When in doubt, leave the upstream files
untouched and load them as data.
