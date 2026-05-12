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

# All synthesizable RTL sources. New files added under rtl/ are picked up
# automatically.
RTL_SRCS    := $(shell find $(RTL_DIR) -name '*.sv' | sort)

VERILATOR   ?= verilator
VFLAGS_LINT := --lint-only -Wall -Wno-DECLFILENAME --top-module $(TOP)
VFLAGS_BUILD := --cc --exe --build -O2 \
                --trace \
                --top-module $(TOP) \
                -Wall -Wno-DECLFILENAME \
                -Mdir $(BUILD_DIR)

SIM_BIN     := $(BUILD_DIR)/V$(TOP)

# ---- Targets ----------------------------------------------------------------

.PHONY: all lint sim test clean

all: sim

lint:
	@echo ">>> verilator --lint-only"
	$(VERILATOR) $(VFLAGS_LINT) $(RTL_SRCS)
	@echo "lint OK"

sim: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(TB_CPP)
	@echo ">>> verilator build"
	$(VERILATOR) $(VFLAGS_BUILD) $(RTL_SRCS) $(TB_CPP)

test: sim
	@echo ">>> running skeleton smoke test"
	$(SIM_BIN) +cycles=16 +quiet
	@echo "test OK"

clean:
	@echo ">>> cleaning"
	rm -rf $(BUILD_DIR)
	@find $(ROOT_DIR) -name '*.vcd' -delete
	@find $(ROOT_DIR) -name '*.fst' -delete
