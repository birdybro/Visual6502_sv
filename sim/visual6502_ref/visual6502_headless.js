// SPDX-License-Identifier: MIT
//
// Headless port of the Visual6502 transistor-level reference simulator.
//
// This module is a faithful re-expression of the engine in
//   visual6502-master/chipsim.js
//   visual6502-master/wires.js  (setupNodes / setupTransistors only)
//   visual6502-master/macros.js (halfStep / bus handlers / readers only)
//
// with the browser/DOM dependencies removed. The transistor netlist, segment
// data, and node-name table are loaded as data from the original files.
//
// See docs/visual6502_mapping.md for the rationale and pin/signal mapping.

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REF_DIR = path.join(__dirname, '..', '..', 'visual6502-master');

// Load the upstream JS data files in a sandboxed vm context. Their `var`
// declarations land as properties of the context object.
const dataCtx = vm.createContext({});
for (const f of ['segdefs.js', 'transdefs.js', 'nodenames.js']) {
    const src = fs.readFileSync(path.join(REF_DIR, f), 'utf8');
    vm.runInContext(src, dataCtx, { filename: f });
}

const segdefs = dataCtx.segdefs;
const transdefs = dataCtx.transdefs;
const nodenames = dataCtx.nodenames;

const ngnd = nodenames['vss'];
const npwr = nodenames['vcc'];

const nodes = [];
const transistors = Object.create(null);
const memory = new Uint8Array(0x10000);

let recalclist = [];
let recalcHash = new Set();
let group = [];

let writeTrap = null;       // optional callback(addr, data)
let readTrap = null;        // optional callback(addr) -> data or undefined

function setupNodes() {
    for (const seg of segdefs) {
        const w = seg[0];
        if (nodes[w] === undefined) {
            nodes[w] = {
                num: w,
                pullup: seg[1] === '+',
                pulldown: false,
                state: false,
                gates: [],
                c1c2s: [],
            };
        }
    }
}

function setupTransistors() {
    for (const tdef of transdefs) {
        const name = tdef[0];
        const gate = tdef[1];
        let c1 = tdef[2];
        let c2 = tdef[3];
        if (c1 === ngnd) { c1 = c2; c2 = ngnd; }
        if (c1 === npwr) { c1 = c2; c2 = npwr; }
        const trans = { name, on: false, gate, c1, c2 };
        nodes[gate].gates.push(trans);
        nodes[c1].c1c2s.push(trans);
        nodes[c2].c1c2s.push(trans);
        transistors[name] = trans;
    }
}

function addNodeToGroup(i) {
    if (group.indexOf(i) !== -1) return;
    group.push(i);
    if (i === ngnd) return;
    if (i === npwr) return;
    const cc = nodes[i].c1c2s;
    for (let k = 0; k < cc.length; k++) {
        const t = cc[k];
        if (!t.on) continue;
        const other = (t.c1 === i) ? t.c2 : t.c1;
        addNodeToGroup(other);
    }
}

function getNodeGroup(i) {
    group = [];
    addNodeToGroup(i);
}

function getNodeValue() {
    if (group.indexOf(ngnd) !== -1) return false;
    if (group.indexOf(npwr) !== -1) return true;
    for (let k = 0; k < group.length; k++) {
        const n = nodes[group[k]];
        if (n.pullup) return true;
        if (n.pulldown) return false;
        if (n.state) return true;
    }
    return false;
}

function addRecalcNode(nn) {
    if (nn === ngnd) return;
    if (nn === npwr) return;
    if (recalcHash.has(nn)) return;
    recalclist.push(nn);
    recalcHash.add(nn);
}

function turnTransistorOn(t) {
    if (t.on) return;
    t.on = true;
    addRecalcNode(t.c1);
}

function turnTransistorOff(t) {
    if (!t.on) return;
    t.on = false;
    addRecalcNode(t.c1);
    addRecalcNode(t.c2);
}

function recalcNode(node) {
    if (node === ngnd) return;
    if (node === npwr) return;
    getNodeGroup(node);
    const newState = getNodeValue();
    for (let k = 0; k < group.length; k++) {
        const n = nodes[group[k]];
        if (n.state === newState) continue;
        n.state = newState;
        for (let j = 0; j < n.gates.length; j++) {
            const t = n.gates[j];
            if (n.state) turnTransistorOn(t);
            else turnTransistorOff(t);
        }
    }
}

function recalcNodeList(list) {
    recalclist = [];
    recalcHash = new Set();
    for (let j = 0; j < 100; j++) {
        if (list.length === 0) return;
        for (let k = 0; k < list.length; k++) recalcNode(list[k]);
        list = recalclist;
        recalclist = [];
        recalcHash = new Set();
    }
}

function setHigh(name) {
    const nn = nodenames[name];
    nodes[nn].pullup = true;
    nodes[nn].pulldown = false;
    recalcNodeList([nn]);
}

function setLow(name) {
    const nn = nodenames[name];
    nodes[nn].pullup = false;
    nodes[nn].pulldown = true;
    recalcNodeList([nn]);
}

function isNodeHigh(nn) { return nodes[nn].state; }

function readBits(name, n) {
    let res = 0;
    for (let i = 0; i < n; i++) {
        const nn = nodenames[name + i];
        res += (isNodeHigh(nn) ? 1 : 0) << i;
    }
    return res >>> 0;
}

function readAddressBus() { return readBits('ab', 16); }
function readDataBus() { return readBits('db', 8); }
function readA() { return readBits('a', 8); }
function readX() { return readBits('x', 8); }
function readY() { return readBits('y', 8); }
function readS() { return readBits('s', 8); }
function readP() {
    // p4 / p5 nodes are not real status bits; reconstruct the canonical byte
    // with bit 5 (unused) = 1, bit 4 (B) = 1 (the value as seen by PHP/BRK on the
    // chip output, not the in-register storage). For an internal-state view we
    // return what the visible storage nodes hold.
    let p = 0;
    p |= isNodeHigh(nodenames['p0']) ? 0x01 : 0;
    p |= isNodeHigh(nodenames['p1']) ? 0x02 : 0;
    p |= isNodeHigh(nodenames['p2']) ? 0x04 : 0;
    p |= isNodeHigh(nodenames['p3']) ? 0x08 : 0;
    // bit 4 is not a stored bit; emit 0 for stored view
    p |= 0x20; // bit 5 is always reported set
    p |= isNodeHigh(nodenames['p6']) ? 0x40 : 0;
    p |= isNodeHigh(nodenames['p7']) ? 0x80 : 0;
    return p;
}
function readIR() { return readBits('ir', 8); }
function readPC() { return (readBits('pch', 8) << 8) + readBits('pcl', 8); }

function writeDataBus(x) {
    const recalcs = [];
    for (let i = 0; i < 8; i++) {
        const nn = nodenames['db' + i];
        const n = nodes[nn];
        if ((x & 1) === 0) { n.pulldown = true; n.pullup = false; }
        else { n.pulldown = false; n.pullup = true; }
        recalcs.push(nn);
        x >>= 1;
    }
    recalcNodeList(recalcs);
}

function mRead(a) {
    if (readTrap) {
        const r = readTrap(a);
        if (r !== undefined) return r & 0xff;
    }
    return memory[a];
}
function mWrite(a, d) {
    memory[a] = d & 0xff;
    if (writeTrap) writeTrap(a, d & 0xff);
}

function setMemory(buf, addr) {
    addr = addr & 0xffff;
    for (let i = 0; i < buf.length; i++) {
        memory[(addr + i) & 0xffff] = buf[i] & 0xff;
    }
}
function setByte(a, d) { memory[a & 0xffff] = d & 0xff; }
function setResetVector(v) {
    memory[0xfffc] = v & 0xff;
    memory[0xfffd] = (v >> 8) & 0xff;
}
function setIrqVector(v) {
    memory[0xfffe] = v & 0xff;
    memory[0xffff] = (v >> 8) & 0xff;
}
function setNmiVector(v) {
    memory[0xfffa] = v & 0xff;
    memory[0xfffb] = (v >> 8) & 0xff;
}

function setWriteTrap(fn) { writeTrap = fn; }
function setReadTrap(fn) { readTrap = fn; }

function handleBusRead() {
    if (isNodeHigh(nodenames['rw'])) {
        const a = readAddressBus();
        const d = mRead(a);
        writeDataBus(d);
    }
}
function handleBusWrite() {
    if (!isNodeHigh(nodenames['rw'])) {
        const a = readAddressBus();
        const d = readDataBus();
        mWrite(a, d);
    }
}

function allNodes() {
    const res = [];
    for (let i = 0; i < nodes.length; i++) {
        if (nodes[i] === undefined) continue;
        if (i === npwr || i === ngnd) continue;
        res.push(i);
    }
    return res;
}

function halfStep() {
    const clk = isNodeHigh(nodenames['clk0']);
    if (clk) { setLow('clk0'); handleBusRead(); }
    else { setHigh('clk0'); handleBusWrite(); }
}

// Power-on portion: float all nodes, set vss/vcc, hold reset low, toggle clk0
// 8 times to let the synchronous logic settle. Stops with reset still asserted
// and clk0 low. `releaseReset()` must be called separately.
function initPower() {
    for (let i = 0; i < nodes.length; i++) {
        if (nodes[i] !== undefined) nodes[i].state = false;
    }
    nodes[ngnd].state = false;
    nodes[npwr].state = true;
    for (const tn in transistors) transistors[tn].on = false;

    setLow('res');
    setLow('clk0');
    setHigh('rdy');
    setLow('so');
    setHigh('irq');
    setHigh('nmi');
    recalcNodeList(allNodes());
    for (let i = 0; i < 8; i++) { setHigh('clk0'); setLow('clk0'); }
}

// Deassert reset. The chip's reset sequence (7 cycles of vector fetch) will
// then run as `halfStep()` is called.
function releaseReset() { setHigh('res'); }

// Convenience: power on, release reset, and run `stabilizeHalfsteps` halfsteps
// to skip past the reset sequence. The upstream JS uses 18 halfsteps. Pass 0
// to start tracing from cycle 0 of the reset itself.
function initChip(stabilizeHalfsteps) {
    if (stabilizeHalfsteps === undefined) stabilizeHalfsteps = 18;
    initPower();
    releaseReset();
    for (let i = 0; i < stabilizeHalfsteps; i++) halfStep();
}

// Run for `cycles` full bus cycles after init. Calls onCycle(cycleIndex)
// after each completed cycle if provided.
function run(cycles, onCycle) {
    for (let c = 0; c < cycles; c++) {
        halfStep();
        halfStep();
        if (onCycle) onCycle(c);
    }
}

setupNodes();
setupTransistors();

module.exports = {
    nodenames,
    initChip, initPower, releaseReset, halfStep, run,
    setHigh, setLow, isNodeHigh,
    readAddressBus, readDataBus,
    readA, readX, readY, readS, readP, readIR, readPC,
    mRead, mWrite,
    setMemory, setByte, setResetVector, setIrqVector, setNmiVector,
    setWriteTrap, setReadTrap,
};
