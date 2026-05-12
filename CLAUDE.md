# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

This repo is an in-progress effort to convert the [visual6502](http://visual6502.org/) transistor-level JavaScript simulator into **synthesizable SystemVerilog** for the MOS 6502. At the time of writing there is no SystemVerilog source in the repo yet — only the reference JS implementation under `visual6502-master/`. New work will introduce `.sv` modules, a testbench, and a build/sim flow; update this file when those land.

## Repository layout

- `visual6502-master/` — **read-only reference**, a snapshot of the upstream visual6502 JS simulator (MIT, Brian/Barry Silverman et al.). Do not edit; it is the source of truth for chip data and reference behavior the SV port must match.
- Top level — currently just `README.md` and `LICENSE`. New SystemVerilog modules, testbenches, and tooling belong here (or in new subdirectories), not inside `visual6502-master/`.

## How the reference simulator works (the model the SV port must replicate)

The JS simulator is transistor-level, not RTL. Understanding its data model is essential because the SV port has to reproduce its semantics, not invent new ones.

Three large generated data files describe a specific 6502 die (revision D):
- `segdefs.js` (~1 MB) — polygon geometry per node, used only for the visual layout. **Not needed for synthesis.**
- `transdefs.js` (~265 KB) — every transistor as `[name, gate, c1, c2, bbox, ...]`. This is the netlist.
- `nodenames.js` — symbolic names (e.g. `db0`, `rw`, `sync`, `clk0`, `res`, `pc`, `ir`) → node numbers. These are the only "named" signals; everything else is just a numbered node.

The simulator engine in `chipsim.js` + `wires.js` is a switch-level event simulator, not gate-level:
- `setupNodes` / `setupTransistors` (`wires.js`) build adjacency from `segdefs` / `transdefs`. Each node tracks `pullup`, `pulldown`, `state`, plus lists `gates` (transistors it controls) and `c1c2s` (transistors it connects through).
- `recalcNodeList` (`chipsim.js`) iterates up to 100 times until the network settles. For each node it floods through *on* transistors via `getNodeGroup` / `addNodeToGroup` to collect electrically connected nodes, computes the group's logic value with `getNodeValue` (gnd → 0, pwr → 1, otherwise first pullup/pulldown/state wins), then propagates by toggling transistors whose gate just changed.
- Special nodes `ngnd = nodenames['vss']` and `npwr = nodenames['vcc']` short-circuit the recursion.
- `setHigh` / `setLow` drive pad inputs (e.g. `clk0`, `res`); `isNodeHigh` reads pad outputs.

`macros.js` sits above the engine and provides cycle-level helpers: `halfStep`, `goUntilSync`, reset sequencing, memory model (`mWrite`/`mRead`), and the `presetLogLists` that name the architecturally interesting nodes (`ab`, `db`, `pc`, `a`, `x`, `y`, `s`, `p`, `ir`, `tcstate`, `pd`, ALU buses, PLA outputs, IRQ/NMI/RESET, etc.).

Implications for the SV port:
- The transistor netlist is authoritative — `transdefs.js` is the spec. The synthesizable conversion needs to reconstruct logic (NMOS pull-down stacks vs. depletion pull-ups, pass transistors, dynamic nodes / precharge, the PLA) from this netlist, not from any high-level description.
- Pad-level signals to expose on the SV top module are the entries in `nodenames.js` flagged as pads in the JS (`res`, `rw`, `db0..7`, `ab0..15`, `clk0`, `clk1out`, `clk2out`, `sync`, `irq`, `nmi`, `rdy`, `so`).
- Equivalence-check strategy: the JS simulator (running in Node or a browser) is the golden model. A useful SV testbench harness reads the same `nodenames` and compares the `presetLogLists` signals cycle-by-cycle on identical programs (see `testprogram.js`).

## Commands

No build, lint, or test tooling exists in this repo yet. The reference JS simulator runs in a browser by opening `visual6502-master/index.html` (or `expert.html`) — it has no Node build step. When SystemVerilog tooling is added (e.g. Verilator, Icarus, a formal flow), document the commands here.
