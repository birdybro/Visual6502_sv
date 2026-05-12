# SPDX-License-Identifier: MIT
#
# Top-level Makefile for Visual6502_sv.
#
# Targets:
#   make lint    Run verilator --lint-only on all RTL.
#   make sim     Build the Verilator simulation binary.
#   make test    Build and run the simulation suite; non-zero exit on failure.
#   make clean   Remove build artifacts.

# ---- Configuration ----------------------------------------------------------

ROOT_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR     := $(ROOT_DIR)/rtl
SIM_DIR     := $(ROOT_DIR)/sim/verilator
BUILD_DIR   := $(SIM_DIR)/obj_dir
TOP         := mos6502_core
TB_CPP      := $(SIM_DIR)/tb_$(TOP).cpp

# All synthesizable RTL sources. Packages must precede their users on the
# command line, so list *_pkg.sv files first.
RTL_PKGS    := $(shell find $(RTL_DIR) -name '*_pkg.sv' | sort)
RTL_MODS    := $(shell find $(RTL_DIR) -name '*.sv' -not -name '*_pkg.sv' | sort)
RTL_SRCS    := $(RTL_PKGS) $(RTL_MODS)

VERILATOR   ?= verilator
VFLAGS_LINT := --lint-only -Wall -Wno-DECLFILENAME --top-module $(TOP)
VFLAGS_BUILD := --cc --exe --build -O2 \
                --trace \
                --top-module $(TOP) \
                -Wall -Wno-DECLFILENAME \
                -Mdir $(BUILD_DIR)

SIM_BIN     := $(BUILD_DIR)/V$(TOP)

NODE        ?= node
PYTHON      ?= python3

REF_RUN     := $(ROOT_DIR)/tools/extract_visual6502/run.js
TRACE_CMP   := $(ROOT_DIR)/tools/trace_compare/compare.py
TRACE_DIR   := $(ROOT_DIR)/tests/traces

# ---- Targets ----------------------------------------------------------------

.PHONY: all lint sim test clean trace-ref-reset trace-ref-nop trace-self-check \
        test-m3 test-m4 test-m5 test-m6 test-m6-irq

all: sim

lint:
	@echo ">>> verilator --lint-only"
	$(VERILATOR) $(VFLAGS_LINT) $(RTL_SRCS)
	@echo "lint OK"

sim: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(TB_CPP)
	@echo ">>> verilator build"
	$(VERILATOR) $(VFLAGS_BUILD) $(RTL_SRCS) $(TB_CPP)

test: sim trace-self-check test-m3 test-m4 test-m5 test-m6 test-m6-irq
	@echo "all tests OK"

# ---- Per-milestone RTL tests -----------------------------------------------
#
# Each test generates an RTL trace by running a known program through the
# Verilator harness, then compares it cycle-by-cycle to the matching
# Visual6502 reference trace. The reference is offset by 3 cycles (the
# power-on settling that the real silicon shows but the RTL doesn't).
#
# RTL traces are written to tests/traces/rtl_*.tsv which is .gitignored.

RTL_TRACE_DIR := $(TRACE_DIR)
NOP_LOOP_BIN  := $(ROOT_DIR)/tests/asm/nop_loop.bin

M4_LOADSTORE_BIN := $(ROOT_DIR)/tests/asm/m4_loadstore.bin

# Trace cadence alignment: Visual6502 has 3 power-on settling cycles and one
# more before R0 of the reset takes deterministic effect; the RTL has none.
# So skip 9 ref / 6 rtl to align both traces on the first opcode fetch.
REF_SKIP_TO_FETCH := 9
RTL_SKIP_TO_FETCH := 6

# M3: reset + opcode fetch + NOP. Compares the RTL bus against the Visual6502
# NOP-loop reference from the first opcode fetch onwards.
test-m3: sim
	@echo ">>> M3 test: reset + fetch + NOP"
	$(SIM_BIN) +mem=$(NOP_LOOP_BIN) +cycles=80 \
	        +trace=$(RTL_TRACE_DIR)/rtl_nop_loop.tsv +quiet
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/nop_loop.tsv \
	        $(RTL_TRACE_DIR)/rtl_nop_loop.tsv \
	        --ref-skip $(REF_SKIP_TO_FETCH) --rtl-skip $(RTL_SKIP_TO_FETCH) \
	        --fields ab,db,rw,sync
	@echo "M3 OK"

# M4: load/store/transfer across every addressing mode and the page-crossing
# dummy cycle on indexed loads/stores. 194 cycles of program execution.
test-m4: sim tests/asm/m4_loadstore.bin
	@echo ">>> M4 test: loads/stores/transfers across all addressing modes"
	$(SIM_BIN) +mem=$(M4_LOADSTORE_BIN) +cycles=200 \
	        +trace=$(RTL_TRACE_DIR)/rtl_m4_loadstore.tsv +quiet
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/m4_loadstore.tsv \
	        $(RTL_TRACE_DIR)/rtl_m4_loadstore.tsv \
	        --ref-skip $(REF_SKIP_TO_FETCH) --rtl-skip $(RTL_SKIP_TO_FETCH) \
	        --fields ab,db,rw,sync
	@echo "M4 OK"

tests/asm/m4_loadstore.bin: tests/asm/build_tests.py
	$(PYTHON) $(ROOT_DIR)/tests/asm/build_tests.py m4_loadstore --out $@

M5_ALU_BIN := $(ROOT_DIR)/tests/asm/m5_alu.bin

# M5: ALU ops, RMW, decimal-mode ADC/SBC, flag set/clear, INX/INY/DEX/DEY,
# accumulator and memory shifts. 494 cycles of program execution.
test-m5: sim tests/asm/m5_alu.bin
	@echo ">>> M5 test: ALU, RMW, decimal mode, flag ops"
	$(SIM_BIN) +mem=$(M5_ALU_BIN) +cycles=500 \
	        +trace=$(RTL_TRACE_DIR)/rtl_m5_alu.tsv +quiet
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/m5_alu.tsv \
	        $(RTL_TRACE_DIR)/rtl_m5_alu.tsv \
	        --ref-skip $(REF_SKIP_TO_FETCH) --rtl-skip $(RTL_SKIP_TO_FETCH) \
	        --fields ab,db,rw,sync
	@echo "M5 OK"

tests/asm/m5_alu.bin: tests/asm/build_tests.py
	$(PYTHON) $(ROOT_DIR)/tests/asm/build_tests.py m5_alu --out $@

M6_STACK_BIN := $(ROOT_DIR)/tests/asm/m6_stack.bin

# M6: stack push/pull, JSR/RTS, BRK/RTI. 174 cycles.
test-m6: sim tests/asm/m6_stack.bin
	@echo ">>> M6 test: stack, JSR/RTS, BRK/RTI"
	$(SIM_BIN) +mem=$(M6_STACK_BIN) +cycles=180 \
	        +trace=$(RTL_TRACE_DIR)/rtl_m6_stack.tsv +quiet
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/m6_stack.tsv \
	        $(RTL_TRACE_DIR)/rtl_m6_stack.tsv \
	        --ref-skip $(REF_SKIP_TO_FETCH) --rtl-skip $(RTL_SKIP_TO_FETCH) \
	        --fields ab,db,rw,sync
	@echo "M6 OK"

tests/asm/m6_stack.bin: tests/asm/build_tests.py
	$(PYTHON) $(ROOT_DIR)/tests/asm/build_tests.py m6_stack_subroutines --out $@

# M6 IRQ injection: re-runs the M6 program with irq_n asserted at cycle 100
# (ref) / 97 (rtl). 224 cycles match (covers main program + IRQ entry +
# RTI return + post-RTI execution).
test-m6-irq: sim tests/asm/m6_stack.bin
	@echo ">>> M6 IRQ test: irq_n pulse during program"
	$(NODE) $(REF_RUN) $(M6_STACK_BIN) --include-reset --cycles 250 \
	        --irq-at 100 --output $(TRACE_DIR)/m6_irq.tsv
	$(SIM_BIN) +mem=$(M6_STACK_BIN) +cycles=230 +irq_at=97 \
	        +trace=$(RTL_TRACE_DIR)/rtl_m6_irq.tsv +quiet
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/m6_irq.tsv \
	        $(RTL_TRACE_DIR)/rtl_m6_irq.tsv \
	        --ref-skip $(REF_SKIP_TO_FETCH) --rtl-skip $(RTL_SKIP_TO_FETCH) \
	        --fields ab,db,rw,sync
	@echo "M6-IRQ OK"

# ---- M2: Visual6502 reference trace targets --------------------------------

# Re-generate the canonical reset+BRK trace from empty memory. The first 8
# cycles cover the reset vector fetch sequence; subsequent cycles run BRK in
# a loop (memory full of $00 = BRK opcode).
trace-ref-reset:
	@echo ">>> generating reference reset trace"
	$(NODE) $(REF_RUN) --no-program --include-reset --cycles 24 \
	        --output $(TRACE_DIR)/reset_brk.tsv

# Re-generate the NOP-loop reference trace. tests/asm/nop_loop.bin is 256
# bytes of $EA loaded at $0000, reset vector $0000.
trace-ref-nop:
	@echo ">>> generating reference NOP-loop trace"
	$(NODE) $(REF_RUN) $(ROOT_DIR)/tests/asm/nop_loop.bin --include-reset \
	        --cycles 32 --output $(TRACE_DIR)/nop_loop.tsv

# Tooling sanity check: comparing a reference trace against itself must pass.
trace-self-check:
	@echo ">>> trace comparator self-test"
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/reset_brk.tsv $(TRACE_DIR)/reset_brk.tsv \
	        --quiet
	@echo "trace tooling OK"

clean:
	@echo ">>> cleaning"
	rm -rf $(BUILD_DIR)
	@find $(ROOT_DIR) -name '*.vcd' -delete
	@find $(ROOT_DIR) -name '*.fst' -delete
