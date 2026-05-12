// SPDX-License-Identifier: MIT
//
// tb_mos6502_core — Verilator harness for the 6502 core.
//
// Models a 64KB memory backing the bus. Loads a program binary at a chosen
// address, sets the reset vector, releases reset, runs N bus cycles, and
// emits a TSV trace matching tools/extract_visual6502/run.js so the comparator
// can diff RTL vs Visual6502 reference cycle-by-cycle.
//
// Plusargs:
//   +mem=path             Binary to load.
//   +load_addr=0xNNNN     Load address (default 0x0000).
//   +reset_vec=0xNNNN     Reset vector at $FFFC/D (default = load_addr).
//   +irq_vec=0xNNNN       IRQ/BRK vector at $FFFE/F.
//   +nmi_vec=0xNNNN       NMI vector at $FFFA/B.
//   +cycles=N             Bus cycles to run after reset release (default 64).
//   +trace=path           TSV trace output (default: stdout).
//   +vcd=path             VCD waveform output.
//   +quiet                Suppress non-trace stdout.

#include "Vmos6502_core.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

uint8_t mem[0x10000] = {0};

uint32_t parse_num(const char *s) {
    if (!s) return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        return std::strtoul(s + 2, nullptr, 16);
    }
    return std::strtoul(s, nullptr, 10);
}

const char *get_plusarg(int argc, char **argv, const char *name) {
    const size_t nl = std::strlen(name);
    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (a[0] != '+') continue;
        if (std::strncmp(a + 1, name, nl) != 0) continue;
        if (a[1 + nl] == '=') return a + 2 + nl;
        if (a[1 + nl] == '\0') return "";  // presence-only flag
    }
    return nullptr;
}

bool load_binary(const char *path, uint32_t load_addr) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        std::fprintf(stderr, "ERROR: cannot open %s\n", path);
        return false;
    }
    std::vector<char> buf((std::istreambuf_iterator<char>(in)),
                          std::istreambuf_iterator<char>());
    for (size_t i = 0; i < buf.size(); ++i) {
        uint32_t a = (load_addr + i) & 0xFFFF;
        mem[a] = static_cast<uint8_t>(buf[i]);
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Parse plusargs.
    const char *mem_path     = get_plusarg(argc, argv, "mem");
    const char *load_addr_s  = get_plusarg(argc, argv, "load_addr");
    const char *reset_vec_s  = get_plusarg(argc, argv, "reset_vec");
    const char *irq_vec_s    = get_plusarg(argc, argv, "irq_vec");
    const char *nmi_vec_s    = get_plusarg(argc, argv, "nmi_vec");
    const char *cycles_s     = get_plusarg(argc, argv, "cycles");
    const char *trace_path   = get_plusarg(argc, argv, "trace");
    const char *vcd_path     = get_plusarg(argc, argv, "vcd");
    const bool quiet         = get_plusarg(argc, argv, "quiet") != nullptr;

    uint32_t load_addr = load_addr_s ? parse_num(load_addr_s) : 0x0000;
    uint32_t reset_vec = reset_vec_s ? parse_num(reset_vec_s) : load_addr;
    int      max_cycles = cycles_s   ? static_cast<int>(parse_num(cycles_s)) : 64;

    if (mem_path && mem_path[0] != '\0') {
        if (!load_binary(mem_path, load_addr)) return 2;
    }
    mem[0xFFFC] = reset_vec & 0xFF;
    mem[0xFFFD] = (reset_vec >> 8) & 0xFF;
    if (irq_vec_s) {
        uint32_t v = parse_num(irq_vec_s);
        mem[0xFFFE] = v & 0xFF; mem[0xFFFF] = (v >> 8) & 0xFF;
    }
    if (nmi_vec_s) {
        uint32_t v = parse_num(nmi_vec_s);
        mem[0xFFFA] = v & 0xFF; mem[0xFFFB] = (v >> 8) & 0xFF;
    }

    auto *dut = new Vmos6502_core;

    VerilatedVcdC *tfp = nullptr;
    if (vcd_path && vcd_path[0] != '\0') {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open(vcd_path);
    }

    // Trace sink.
    std::FILE *tf = stdout;
    bool tf_owned = false;
    if (trace_path && trace_path[0] != '\0') {
        tf = std::fopen(trace_path, "w");
        if (!tf) {
            std::fprintf(stderr, "ERROR: cannot open trace %s\n", trace_path);
            return 2;
        }
        tf_owned = true;
    }
    std::fprintf(tf, "cycle\tphi0\tab\tdb\trw\tsync\ta\tx\ty\ts\tp\tpc\tir\n");

    dut->clk     = 0;
    dut->reset_n = 0;
    dut->irq_n   = 1;
    dut->nmi_n   = 1;
    dut->ready   = 1;
    dut->so_n    = 1;
    dut->data_in = 0;

    uint64_t sim_time = 0;

    // Drive one bus cycle and emit one trace row.
    // We model the bus as: address is valid throughout the cycle, memory
    // presents data_in continuously, rising clk samples both. For writes, we
    // capture data_out at the falling edge (just before the next rising edge).
    auto run_cycle = [&](int cycle_idx) -> void {
        // Address is combinational from current state; ensure data_in
        // reflects current address before the rising edge.
        dut->data_in = mem[dut->address];
        if (tfp) tfp->dump(sim_time);
        sim_time += 1;

        dut->clk = 1;
        dut->eval();
        if (tfp) tfp->dump(sim_time);
        sim_time += 1;

        // After the rising edge, state and registers have updated. If the
        // PREVIOUS cycle was a write, sample data_out and commit to memory
        // BEFORE the new address takes effect via the new state -> AB path.
        // In our single-edge model, address_d updates combinationally on the
        // rising edge based on state_d, so we sample using "rw==0 at this
        // post-edge point reflects the just-issued bus action" only if we
        // are careful.
        //
        // Simpler model: rw and address_d are both combinational from the
        // current state_q (now the just-loaded state_d). The write happens on
        // the SAME cycle. We capture (address, rw, data_out) once and act on
        // it now; the trace reflects the post-edge snapshot, matching how the
        // Visual6502 reference samples at end-of-cycle.
        if (!dut->rw) {
            mem[dut->address] = dut->data_out;
        }

        // Emit trace row sampled at the end of the cycle.
        std::fprintf(tf,
                     "%d\t1\t%04x\t%02x\t%d\t%d\t%02x\t%02x\t%02x\t%02x\t%02x\t%04x\t%02x\n",
                     cycle_idx,
                     static_cast<unsigned>(dut->address & 0xFFFF),
                     static_cast<unsigned>(mem[dut->address] & 0xFF),
                     dut->rw ? 1 : 0,
                     dut->sync ? 1 : 0,
                     // Register-file fields not yet exposed by the module
                     // boundary. Reported as zero for now; the trace
                     // comparator filters via --fields.
                     0, 0, 0, 0, 0, 0, 0);

        // Falling edge.
        dut->clk = 0;
        dut->eval();
    };

    // Hold reset for a few cycles, then release.
    for (int i = 0; i < 4; ++i) {
        dut->data_in = mem[dut->address];
        sim_time += 1;
        dut->clk = 1;
        dut->eval();
        sim_time += 1;
        dut->clk = 0;
        dut->eval();
    }
    dut->reset_n = 1;

    for (int c = 0; c < max_cycles && !Verilated::gotFinish(); ++c) {
        run_cycle(c);
    }

    if (!quiet) {
        std::fprintf(stderr, "ran %d cycles; final PC visible-on-bus = $%04X\n",
                     max_cycles, static_cast<unsigned>(dut->address & 0xFFFF));
    }

    if (tf_owned) std::fclose(tf);
    if (tfp) { tfp->close(); delete tfp; }
    delete dut;
    return 0;
}
