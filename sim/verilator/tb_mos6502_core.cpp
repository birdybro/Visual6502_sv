// SPDX-License-Identifier: MIT
//
// tb_mos6502_core — minimal Verilator harness for the 6502 core skeleton.
//
// M1 goal: prove that the build flow works and that the core toggles. It
// drives clk, holds reset for a few cycles, then runs for a configurable
// number of cycles while printing a one-line-per-cycle trace.
//
// Future milestones will replace this with a real test harness backed by
// `sim/cpp/` (memory model, trace I/O, plusarg-driven program loading).

#include "Vmos6502_core.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

constexpr int kDefaultCycles = 32;

void usage(const char *argv0) {
    std::fprintf(stderr,
                 "usage: %s [+cycles=N] [+vcd=path.vcd] [+quiet]\n",
                 argv0);
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    int max_cycles = kDefaultCycles;
    std::string vcd_path;
    bool quiet = false;

    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (!std::strncmp(a, "+cycles=", 8)) {
            max_cycles = std::atoi(a + 8);
        } else if (!std::strncmp(a, "+vcd=", 5)) {
            vcd_path = a + 5;
        } else if (!std::strcmp(a, "+quiet")) {
            quiet = true;
        } else if (!std::strcmp(a, "--help") || !std::strcmp(a, "-h")) {
            usage(argv[0]);
            return 0;
        }
    }

    auto *dut = new Vmos6502_core;

    VerilatedVcdC *tfp = nullptr;
    if (!vcd_path.empty()) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open(vcd_path.c_str());
    }

    // Stimulus defaults.
    dut->clk     = 0;
    dut->reset_n = 0;
    dut->irq_n   = 1;
    dut->nmi_n   = 1;
    dut->ready   = 1;
    dut->so_n    = 1;
    dut->data_in = 0;

    vluint64_t sim_time = 0;
    auto tick = [&]() {
        dut->clk = 0;
        dut->eval();
        if (tfp) tfp->dump(sim_time);
        ++sim_time;
        dut->clk = 1;
        dut->eval();
        if (tfp) tfp->dump(sim_time);
        ++sim_time;
    };

    // Hold reset low for 4 clocks, then release.
    for (int i = 0; i < 4; ++i) tick();
    dut->reset_n = 1;

    if (!quiet) {
        std::printf("cycle\taddress\trw\tsync\tdata_in\tdata_out\n");
    }

    int retval = 0;
    for (int cycle = 0; cycle < max_cycles && !Verilated::gotFinish(); ++cycle) {
        tick();
        if (!quiet) {
            std::printf("%d\t%04x\t%d\t%d\t%02x\t%02x\n", cycle,
                        dut->address, dut->rw, dut->sync, dut->data_in,
                        dut->data_out);
        }
    }

    // Skeleton sanity check: the placeholder PC must have advanced.
    if (dut->address == 0x0000) {
        std::fprintf(stderr, "FAIL: skeleton PC did not advance under clk\n");
        retval = 1;
    } else if (!quiet) {
        std::printf("PASS: skeleton advanced to address=0x%04x\n",
                    dut->address);
    }

    if (tfp) {
        tfp->close();
        delete tfp;
    }
    delete dut;
    return retval;
}
