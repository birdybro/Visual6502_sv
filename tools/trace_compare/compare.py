#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Cycle-by-cycle trace comparator.

Reads two TSV traces with the same header and compares the specified fields
row-by-row. Reports the first mismatch with context and exits non-zero.
"""

import argparse
import sys


def read_trace(path):
    with open(path) as f:
        header = f.readline().rstrip("\n").split("\t")
        rows = []
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            rows.append(dict(zip(header, parts)))
    return header, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("ref", help="Reference trace (Visual6502)")
    ap.add_argument("rtl", help="RTL / DUT trace")
    ap.add_argument(
        "--fields",
        default="ab,db,rw,sync",
        help="Comma-separated fields to compare (default: external bus)",
    )
    ap.add_argument(
        "--context",
        type=int,
        default=3,
        help="Lines of context around a mismatch (default: 3)",
    )
    ap.add_argument(
        "--max-cycles",
        type=int,
        default=None,
        help="Compare only up to N cycles (default: min of both traces)",
    )
    ap.add_argument(
        "--skip",
        type=int,
        default=0,
        help="Skip the first N cycles of both traces before comparing",
    )
    ap.add_argument(
        "--ref-skip",
        type=int,
        default=0,
        help="Additional skip applied only to the reference trace",
    )
    ap.add_argument(
        "--rtl-skip",
        type=int,
        default=0,
        help="Additional skip applied only to the RTL trace",
    )
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="Only print mismatches / failures, not the OK summary",
    )
    args = ap.parse_args()

    fields = [f.strip() for f in args.fields.split(",") if f.strip()]
    if not fields:
        ap.error("--fields must list at least one field")

    ref_hdr, ref = read_trace(args.ref)
    rtl_hdr, rtl = read_trace(args.rtl)

    missing = [f for f in fields if f not in ref_hdr or f not in rtl_hdr]
    if missing:
        sys.exit(
            "field(s) %r not in both traces (ref: %s, rtl: %s)"
            % (missing, ref_hdr, rtl_hdr)
        )

    ref = ref[args.skip + args.ref_skip:]
    rtl = rtl[args.skip + args.rtl_skip:]
    n = min(len(ref), len(rtl))
    if args.max_cycles is not None:
        n = min(n, args.max_cycles)
    if n == 0:
        sys.exit("no cycles to compare (one trace is empty after --skip)")

    for i in range(n):
        mismatches = [f for f in fields if ref[i][f] != rtl[i][f]]
        if mismatches:
            cyc = args.skip + i
            print("MISMATCH at cycle %d on fields %s" % (cyc, mismatches))
            lo = max(0, i - args.context)
            hi = min(n, i + args.context + 1)
            cols = ["cyc", "src"] + fields
            widths = [max(len(c), 6) for c in cols]
            sep = "  "
            hdr_line = sep.join(c.rjust(w) for c, w in zip(cols, widths))
            print(hdr_line)
            for j in range(lo, hi):
                marker = ">>" if j == i else "  "
                jcyc = args.skip + j
                ref_row = [str(jcyc), "ref"] + [ref[j][f] for f in fields]
                rtl_row = [str(jcyc), "rtl"] + [rtl[j][f] for f in fields]
                print(
                    "%s%s"
                    % (marker, sep.join(c.rjust(w) for c, w in zip(ref_row, widths)))
                )
                print(
                    "%s%s"
                    % (marker, sep.join(c.rjust(w) for c, w in zip(rtl_row, widths)))
                )
            sys.exit(1)

    if not args.quiet:
        print("OK: %d cycles matched on %s" % (n, ",".join(fields)))


if __name__ == "__main__":
    main()
