#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Drive the headless Visual6502 reference and emit a canonical trace.
//
// Usage:
//   run.js [options] <program.bin>
//
// Options:
//   --load-addr 0xNNNN   Load binary at this address (default 0x0000)
//   --reset-vec 0xNNNN   Reset vector at $FFFC/D (default = --load-addr)
//   --cycles N           Bus cycles after init (default 64)
//   --output PATH        Trace output (default: stdout)
//   --no-program         Don't require a program argument; trace an empty bus.
//   --include-reset      Start the trace from the moment reset is released,
//                        so the 7-cycle reset/vector-fetch sequence is captured.
//   --skip-halfsteps N   Skip N halfsteps after reset before tracing.
//                        Default 18 (matches upstream visual6502).

'use strict';

const fs = require('fs');
const path = require('path');

const v = require(path.join(__dirname, '..', '..', 'sim', 'visual6502_ref', 'visual6502_headless'));

function parseNum(s) {
    if (typeof s !== 'string') return NaN;
    if (s.startsWith('0x') || s.startsWith('0X')) return parseInt(s.slice(2), 16);
    return parseInt(s, 10);
}

function usage(exitCode) {
    process.stderr.write(
        'usage: run.js [options] <program.bin>\n' +
        '  --load-addr 0xNNNN   Load binary at this address (default 0x0000)\n' +
        '  --reset-vec 0xNNNN   Reset vector at $FFFC/D (default = load-addr)\n' +
        '  --cycles N           Bus cycles after init (default 64)\n' +
        '  --output PATH        Trace TSV output (default stdout)\n' +
        '  --no-program         Run with empty memory; <program.bin> not required\n' +
        '  --include-reset      Trace from reset release (no skip halfsteps)\n' +
        '  --skip-halfsteps N   Halfsteps to run after reset release before tracing\n' +
        '                       (default 18 = upstream visual6502)\n'
    );
    process.exit(exitCode);
}

let loadAddr = 0x0000;
let resetVec = null;
let cycles = 64;
let output = null;
let prog = null;
let noProgram = false;
let skipHalfsteps = 18;

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--load-addr') loadAddr = parseNum(args[++i]);
    else if (a === '--reset-vec') resetVec = parseNum(args[++i]);
    else if (a === '--cycles') cycles = parseInt(args[++i], 10);
    else if (a === '--output') output = args[++i];
    else if (a === '--no-program') noProgram = true;
    else if (a === '--include-reset') skipHalfsteps = 0;
    else if (a === '--skip-halfsteps') skipHalfsteps = parseInt(args[++i], 10);
    else if (a === '-h' || a === '--help') usage(0);
    else if (!a.startsWith('-')) prog = a;
    else { process.stderr.write('Unknown arg: ' + a + '\n'); usage(2); }
}

if (!prog && !noProgram) usage(2);
if (resetVec === null) resetVec = loadAddr;

if (prog) {
    const bin = fs.readFileSync(prog);
    v.setMemory(bin, loadAddr);
}
v.setResetVector(resetVec);

v.initChip(skipHalfsteps);

const out = output ? fs.createWriteStream(output) : process.stdout;
out.write('cycle\tphi0\tab\tdb\trw\tsync\ta\tx\ty\ts\tp\tpc\tir\n');

function hex(n, w) { return (n >>> 0).toString(16).padStart(w, '0'); }

let cycle = 0;
function record() {
    // For DB we report memory[AB] (the bus value the CPU and memory agree on
    // for this cycle): a fresh read sees the byte memory just drove; a write
    // sees the byte that was just committed. readDataBus() reflects the
    // CURRENT pullup/pulldown state of the db nodes which can be stale on
    // write cycles after the chip has stopped driving the bus.
    const ab = v.readAddressBus();
    out.write([
        cycle,
        v.isNodeHigh(v.nodenames['clk0']) ? 1 : 0,
        hex(ab, 4),
        hex(v.mRead(ab), 2),
        v.isNodeHigh(v.nodenames['rw']) ? 1 : 0,
        v.isNodeHigh(v.nodenames['sync']) ? 1 : 0,
        hex(v.readA(), 2),
        hex(v.readX(), 2),
        hex(v.readY(), 2),
        hex(v.readS(), 2),
        hex(v.readP(), 2),
        hex(v.readPC(), 4),
        hex(v.readIR(), 2),
    ].join('\t') + '\n');
}

// Trace cadence: one record per bus cycle, sampled right after the phi2
// transition (when reads have been driven onto db by memory and writes have
// just been committed to memory). After initChip(skip=0), clk0 is LOW. The
// first halfStep enters phi2 (clk0 → high) and runs handleBusWrite; that's
// the point at which writes commit. We record there, *before* the second
// halfStep enters phi1 of the next cycle and starts changing AB/RW.
for (let c = 0; c < cycles; c++) {
    v.halfStep();   // enter phi2: writes commit, db carries the cycle's data
    record();
    v.halfStep();   // enter phi1 of next cycle: CPU presents new outputs
    cycle++;
}

if (output) out.end();
