#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Continuous-integration check: lint + full simulation suite.
# Run from the repo root: `scripts/run_ci.sh`
#
# Exits non-zero on any failure. Suitable for use in CI.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==== verilator --lint-only ===="
make lint

echo "==== sim build ===="
make sim

echo "==== full milestone test suite ===="
make -j1 test

echo "==== ALL OK ===="
