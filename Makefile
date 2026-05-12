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

.PHONY: all lint sim test clean trace-ref-reset trace-ref-nop trace-self-check test-m3

all: sim

lint:
	@echo ">>> verilator --lint-only"
	$(VERILATOR) $(VFLAGS_LINT) $(RTL_SRCS)
	@echo "lint OK"

sim: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(TB_CPP)
	@echo ">>> verilator build"
	$(VERILATOR) $(VFLAGS_BUILD) $(RTL_SRCS) $(TB_CPP)

test: sim trace-self-check test-m3
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

# M3: reset + opcode fetch + NOP. Verifies 64 cycles of bus activity against
# the Visual6502 NOP-loop reference (200+ cycles available; we compare 64).
test-m3: sim
	@echo ">>> M3 test: reset + fetch + NOP"
	$(SIM_BIN) +mem=$(NOP_LOOP_BIN) +cycles=64 \
	        +trace=$(RTL_TRACE_DIR)/rtl_nop_loop.tsv +quiet
	$(PYTHON) $(TRACE_CMP) $(TRACE_DIR)/nop_loop.tsv \
	        $(RTL_TRACE_DIR)/rtl_nop_loop.tsv \
	        --ref-skip 3 --fields ab,db,rw,sync --max-cycles 64
	@echo "M3 OK"

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
