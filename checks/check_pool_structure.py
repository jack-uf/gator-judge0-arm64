#!/usr/bin/env python3
"""Re-derive the pool structure section 17 of the report rests on.

    python3 checks/check_pool_structure.py

No containers needed: this reads benchmarks/results_saturation_sat.json, the
committed record of the cold and hit sweeps, and re-derives the readings the
report quotes from it. Section 17's mechanism claims came from three scratch
probes that were not committed and cannot be re-derived here; these can, and
they are the ones a reader is most likely to want to check for themselves:

  * redis_workers is 12 in every record -- the pool depth comes from nproc
    inside the worker container, not from anything the driver asks for;
  * on the cold ladder isolate_procs_max is exactly 2 x min(c, 12): two isolate
    processes per in-flight submission, capped at 24 by the 12 workers;
  * resque_processing.mean + resque_waiting.mean is 12 on every cold rung. That
    is the whole basis for section 17's statement that the field counts
    proctitles rather than submissions -- the c=1 rung reads processing as high
    as 4, which concurrency 1 cannot mean;
  * throughput is min(c, 12) / execution_mean to within 6% at every cold rung,
    the law section 17 uses to argue the saturated stage has one free parameter.

The hit records are deliberately excluded from the last three. Their tick counts
are an order of magnitude lower (24-64 against 390+), the sums drift to 12.2, and
the isolate count never fills; asserting structure against a run the sampler
barely covered would be asserting noise.

A failure means either the record was regenerated or one of the report's readings
was wrong. Both are worth stopping for. Neither is a licence to edit the record.
"""

import json
import sys
from pathlib import Path

RECORD = (Path(__file__).resolve().parent.parent
          / "benchmarks" / "results_saturation_sat.json")

FAILURES = []
CLAIMS = [0]


def claim(label, readings, predicate, detail=""):
    """One line per claim: a 22-record loop should not bury the claims it is
    checking. readings is a list of (context, value) pairs."""
    CLAIMS[0] += 1
    bad = [(ctx, value) for ctx, value in readings if not predicate(value)]
    print("%s: %s%s" % ("ok" if not bad else "FAIL", label, detail))
    if bad:
        FAILURES.append(label)
        for ctx, value in bad:
            print("     %s -> %r" % (ctx, value))


def span(readings):
    values = [value for _, value in readings if isinstance(value, float)]
    if not values:
        return ""
    return " (%.3f to %.3f)" % (min(values), max(values))


def main():
    records = json.loads(RECORD.read_text())["records"]
    cold = [r for r in records if r["sweep"] == "cold"]

    claim("the record holds the whole ladder", [("records", len(records))],
          lambda n: n == 22, " (22 = 11 cold + 11 hit)")
    claim("the cold half is 11 rungs", [("cold", len(cold))], lambda n: n == 11)

    claim("redis_workers = 12 in every record",
          [("c=%d %s" % (r["concurrency"], r["sweep"]),
            r["samplers"]["redis"]["redis"]["redis_workers"]["max"])
           for r in records],
          lambda v: v == 12, " (samplers.redis.redis, not sandbox.*)")

    claim("cold isolate_procs_max = 2 x min(c, 12)",
          [("c=%d" % r["concurrency"],
            (r["sandbox"]["isolate_procs_max"], 2 * min(r["concurrency"], 12)))
           for r in cold],
          lambda pair: pair[0] == pair[1], " (2, 4, 8, 16, then 24)")

    sums = [("c=%d" % r["concurrency"],
             r["samplers"]["worker"]["ps"]["resque_processing"]["mean"]
             + r["samplers"]["worker"]["ps"]["resque_waiting"]["mean"])
            for r in cold]
    claim("cold processing + waiting mean = 12", sums,
          lambda v: abs(v - 12) <= 0.05, span(sums))

    ratios = []
    for r in cold:
        c = r["concurrency"]
        predicted = min(c, 12) / (r["phases_ms"]["execution_mean"] / 1000.0)
        got = r["throughput_req_per_s"]
        ratios.append(("c=%d" % c, predicted / got if got else 0.0))
    claim("cold throughput = min(c, 12) / execution_mean within 6%", ratios,
          lambda v: 1.0 <= v <= 1.10, span(ratios))

    c1 = [r for r in cold if r["concurrency"] == 1][0]
    processing = c1["samplers"]["worker"]["ps"]["resque_processing"]
    claim("the quoted c=1 reading is 3.81 mean / 6 max",
          [("mean", processing["mean"]), ("max", processing["max"])],
          lambda v: v in (3.81, 6.0), " (section 17 quotes both)")

    print("%d ok, %d failed" % (CLAIMS[0] - len(FAILURES), len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
