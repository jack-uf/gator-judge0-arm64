#!/usr/bin/env python3
"""
Driver for `pch_paired.sh`: writes the five cases into the sandbox and
summarises the interleaved runs into per-shape medians of the per-run ratio.

    python3 benchmarks/benchmark_pch_paired.py --reps 20

Writes `benchmarks/results_pch_paired.json`.
"""

import argparse
import json
import statistics
import subprocess
from pathlib import Path

from benchmark_pch import CONTAINER, SHAPES, docker_exec, source_with_nonce

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(__file__).resolve().parent / "pch_paired.sh"
SHAPE_BY_NAME = dict(SHAPES)

# A spare range, away from the 990s the container check uses and the 0-999 range
# the worker derives from a submission id.
BOX_CANDIDATES = "989 988 987 986 985 984 983 982 981 980 979 978".split()


def write_cases():
    """Put each shape in the box as `<name>.cpp`, from the one definition."""
    parts = ["set -eu", "BOX="]
    parts.append("for c in " + " ".join(BOX_CANDIDATES) + "; do")
    parts.append('  if isolate -b "$c" --init >/dev/null 2>&1; then BOX=$c; break; fi')
    parts.append("done")
    parts.append('[ -n "$BOX" ] || { echo "no free box for writing cases" >&2; exit 1; }')
    parts.append('DIR="/var/local/lib/isolate/$BOX/box/cases"')
    parts.append('rm -rf "$DIR"; mkdir -p "$DIR"')
    for name, shape in SHAPES:
        # No nonce here: a case is compiled many times over, and which of those
        # runs is warm is exactly what the alternation cancels out.
        source = source_with_nonce(shape["source_code"], 0)
        parts.append(f"cat > \"$DIR/{name}.cpp\" <<'CASE_EOF'")
        parts.append(source.rstrip("\n"))
        parts.append("CASE_EOF")
    parts.append('echo "$BOX $DIR"')
    box, cases_dir = docker_exec("\n".join(parts)).strip().splitlines()[-1].split()
    return box, cases_dir


def run_paired(reps, box):
    # The script goes into the container as a file rather than through stdin.
    # `sh -s` reads the loop from stdin, and a child that reads stdin eats the
    # rest of the script: the first case ran and then the loop simply stopped.
    text = SCRIPT.read_text().replace("REPS=${REPS:-20}", f"REPS=${{REPS:-{reps}}}")
    docker_exec(f"cat > /tmp/pch_paired.sh <<'DRIVER_EOF'\n{text}\nDRIVER_EOF")
    result = subprocess.run(
        ["docker", "exec", "-u", "root", "-e", f"BOX_ID={box}", CONTAINER, "sh", "/tmp/pch_paired.sh"],
        capture_output=True, text=True, timeout=3600,
    )
    if result.returncode != 0:
        raise SystemExit(f"pch_paired.sh failed: {result.stderr.strip()}")
    rows = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 7:
            continue
        case, variant, mode, wall_ms, cpu_ms, used, exitcode = fields
        rows.append({
            "case": case, "variant": variant, "mode": mode,
            "wall_ms": int(wall_ms), "cpu_ms": int(cpu_ms),
            "used": used, "exitcode": int(exitcode),
        })
    return rows


def summarise(rows):
    """Median of the per-run ratios. Oracle rows never reach the summary."""
    oracle = [r for r in rows if r["mode"] == "oracle"]
    rows = [r for r in rows if r["mode"] == "timed"]
    summary = {}
    for name, _shape in SHAPES:
        with_pch = sorted([r for r in rows if r["case"] == name and r["variant"] == "withpch"],
                          key=lambda r: r["wall_ms"])
        without = sorted([r for r in rows if r["case"] == name and r["variant"] == "withoutpch"],
                         key=lambda r: r["wall_ms"])
        if not with_pch or not without:
            continue

        # Pair run i of one condition with run i of the other: the alternation
        # means they are neighbours in time, so the ratio is the compiler's
        # doing rather than the host's.
        ratios = [a["wall_ms"] / b["wall_ms"] for a, b in zip(without, with_pch)]
        cpu_ratios = [a["cpu_ms"] / b["cpu_ms"] for a, b in zip(without, with_pch) if b["cpu_ms"]]
        median = lambda values: statistics.median(values) if values else None
        # The oracle rows are the only evidence of *which* form GCC read; they
        # are reported next to the timings rather than mixed into them.
        oracle_used = {
            variant: sorted({r["used"] for r in oracle
                             if r["case"] == name and r["variant"] == variant})
            for variant in ("withpch", "withoutpch")
        }
        summary[name] = {
            "runs_per_condition": len(with_pch),
            "oracle_used_with_pch": oracle_used["withpch"],
            "oracle_used_without_pch": oracle_used["withoutpch"],
            "oracle_exitcodes": sorted({r["exitcode"] for r in oracle}),
            "exitcodes": sorted({r["exitcode"] for r in with_pch + without}),
            "wall_ms_with_pch_p50": median([r["wall_ms"] for r in with_pch]),
            "wall_ms_without_pch_p50": median([r["wall_ms"] for r in without]),
            "wall_ms_with_pch_p95": with_pch[int(round(0.95 * (len(with_pch) - 1)))]["wall_ms"],
            "wall_ms_without_pch_p95": without[int(round(0.95 * (len(without) - 1)))]["wall_ms"],
            "cpu_ms_with_pch_p50": median([r["cpu_ms"] for r in with_pch]),
            "cpu_ms_without_pch_p50": median([r["cpu_ms"] for r in without]),
            "wall_speedup_median": round(median(ratios), 3),
            "cpu_speedup_median": round(median(cpu_ratios), 3),
            "wall_speedup_min": round(min(ratios), 3),
            "wall_speedup_max": round(max(ratios), 3),
        }
    return summary


def check(summary):
    """Refuse to report a run whose own oracle contradicts it.

    Two things have to hold or the numbers mean nothing: the with-PCH runs must
    have consumed the PCH (not silently fallen back to the header), and the
    control case -- which includes no headers at all and therefore cannot be
    affected -- must come out near 1.0. If the control is not near 1.0, the host
    moved more than the effect being measured and the run is void.
    """
    problems = []
    for name, values in summary.items():
        expects_pch = SHAPE_BY_NAME[name]["expects_pch"]
        expected_with = ["pch"] if expects_pch else ["header"]
        if values["oracle_used_with_pch"] != expected_with:
            problems.append(
                f"{name}: with-PCH oracle used {values['oracle_used_with_pch']}, expected {expected_with}")
        if values["oracle_used_without_pch"] != ["header"]:
            problems.append(
                f"{name}: without-PCH oracle used {values['oracle_used_without_pch']}, expected ['header']")
        if set(values["exitcodes"]) != {0}:
            problems.append(f"{name}: exit codes {values['exitcodes']}, expected only 0")
    for name in [n for n, s in SHAPES if not s["expects_pch"]]:
        control = summary.get(name)
        if control and not 0.90 <= control["wall_speedup_median"] <= 1.10:
            problems.append(
                f"{name} control moved {control['wall_speedup_median']}x; it cannot be affected by a "
                "precompiled header, so a value outside 0.90-1.10 means the host drifted more than the effect")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reps", type=int, default=20)
    args = parser.parse_args()

    box, cases_dir = write_cases()
    print(f"cases written to {cases_dir} (box {box})")
    rows = run_paired(args.reps, box)
    timed = sum(1 for r in rows if r["mode"] == "timed")
    print(f"{timed} timed compiles, {args.reps} per case per condition, "
          f"{len(rows) - timed} oracle compiles")

    summary = summarise(rows)
    problems = check(summary)
    for name, values in summary.items():
        # `statistics.median` of an even-length sample is a mean of two runs, so
        # these are floats and must not be formatted as integers.
        print(f"  {name:18s} wall {values['wall_ms_without_pch_p50']:7.1f}ms -> "
              f"{values['wall_ms_with_pch_p50']:7.1f}ms  ({values['wall_speedup_median']}x)  "
              f"cpu {values['cpu_ms_without_pch_p50']:7.1f}ms -> {values['cpu_ms_with_pch_p50']:7.1f}ms  "
              f"({values['cpu_speedup_median']}x)  "
              f"oracle={values['oracle_used_without_pch']}->{values['oracle_used_with_pch']}")

    report = {"reps": args.reps, "problems": problems, "rows": rows, "summary": summary}
    out = ROOT / "benchmarks" / "results_pch_paired.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"wrote {out}")
    if problems:
        for problem in problems:
            print(f"VOID: {problem}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
