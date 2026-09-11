#!/usr/bin/env python3
"""Standalone check for the redis half of the saturation harness's sampler.

    python3 checks/check_saturation_sampler.py

No containers needed: `redis-cli` is replaced by a stub on PATH that answers for
the one queue this stack runs and records every call. The harness samples through
two containers -- only the worker image has `ps`, only the redis container has
`redis-cli` -- and that split produced two mistakes that no record showed as an
error, which is why this check exists:

  * `sandbox_metrics` was handed the worker's summary, so all three redis fields
    of the first 24 records came out None although the sampler had run 123 ticks;
  * the sampler polled `resque:queue:default`, a key that has never existed here.
    The queue is named after JUDGE0_VERSION (`1.13.1`) and Resque deletes a
    queue's list key the moment it drains, so `queue_depth` read a flat 0 through
    a level that spent six seconds of wall time waiting in the queue.

The stub answers only for `resque:queue:1.13.1`, the name the `resque:queues` set
carries, so a hard-coded queue name reads 0 here and fails the check.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "benchmarks"))

import benchmark_saturation as sat  # noqa: E402


FAILURES = []


def check(condition, message):
    print(("ok: " if condition else "FAIL: ") + message)
    if not condition:
        FAILURES.append(message)


# Pending count, worker count and blocked clients are distinct numbers, so a
# field read from a neighbour's slot cannot match by accident.
REDIS_STUB = """#!/bin/sh
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$*" in
  *"SMEMBERS resque:queues") printf '1.13.1\n' ;;
  *"LLEN resque:queue:1.13.1") printf '7\n' ;;
  *"SCARD resque:workers") printf '12\n' ;;
  *"INFO clients") printf '# Clients\r\nconnected_clients:14\r\nblocked_clients:3\r\n' ;;
esac
"""


def run_sampler(mode, work, stub_dir, calls):
    log = work / "samples.log"
    script = (sat.SAMPLER
              .replace("__LOG__", str(log))
              .replace("__STOP__", str(work / "stop-file-never-created"))
              .replace("__MODE__", mode)
              .replace("__IV__", "0.05")
              .replace("__LIMIT__", "1"))
    env = dict(os.environ, PATH=f"{stub_dir}:{os.environ['PATH']}", STUB_CALLS=str(calls))
    subprocess.run(["sh", "-c", script], env=env, timeout=60,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return [line for line in log.read_text().splitlines() if line.strip()]


work = Path(tempfile.mkdtemp(prefix="saturation-sampler-check"))
stub_dir = work / "bin"
stub_dir.mkdir()
calls = work / "redis-calls.log"
calls.write_text("")
stub = stub_dir / "redis-cli"
stub.write_text(REDIS_STUB)
stub.chmod(stub.stat().st_mode | 0o111)

lines = run_sampler("redis", work, stub_dir, calls)
check(len(lines) >= 1, f"the redis sampler produced sample lines ({len(lines)} in a one-second window)")

tokens = lines[0].split()
check(tokens[-len(sat.REDIS_FIELDS):] == ["7", "12", "3"],
      f"the shell prints the redis group last as depth, workers, blocked "
      f"(got {' '.join(tokens[-len(sat.REDIS_FIELDS):])})")

# The cg group is /proc and /sys/fs/cgroup, neither of which macOS has. Padding
# the platform-independent redis group out to the width the worker's Linux
# container produces is what makes the slot assignment assertable here: parse the
# padded line and the three values have to land in the redis fields, not in a
# neighbour's, and the line has to stop being short.
expected = len(sat.FIELD_GROUPS["cg"]) + len(sat.REDIS_FIELDS)
row = sat.parse_sample("redis", " ".join(["0"] * len(sat.FIELD_GROUPS["cg"]) + tokens[-len(sat.REDIS_FIELDS):]))
check(not row["_short"] and row["_tokens"] == expected,
      f"a {expected}-token line is not short: {len(sat.FIELD_GROUPS['cg'])} cg fields then "
      f"{len(sat.REDIS_FIELDS)} redis fields")
check(row["queue_depth"] == 7,
      "queue_depth is the pending count of the queue the resque:queues set names (7)")
check(row["redis_workers"] == 12, "redis_workers is SCARD resque:workers (12)")
check(row["blocked_clients"] == 3, "blocked_clients is INFO clients' blocked_clients (3)")

asked = calls.read_text()
check("LLEN resque:queue:1.13.1" in asked, "the sampler asks for resque:queue:1.13.1, the name in the set")
check("resque:queue:default" not in asked, "the sampler never asks for a queue that is not in the set")
check("SMEMBERS resque:queues" in asked, "queue names come from the set, not from a constant")

# The wiring defect, without a container: the redis values live in the redis
# sampler's summary, and passing the worker's is what left them None.
sandbox = sat.sandbox_metrics(
    {"ps": {"isolate_procs": {"max": 24}}},
    {"redis": {"queue_depth": {"max": 7}, "redis_workers": {"max": 12},
               "blocked_clients": {"max": 3}}},
)
check((sandbox["redis_queue_depth_max"], sandbox["redis_workers"],
       sandbox["redis_blocked_clients_max"]) == (7, 12, 3),
      "sandbox_metrics takes the redis fields from the redis summary")
check(sandbox["isolate_procs_max"] == 24, "sandbox_metrics still takes the ps fields from the worker summary")

print(f"\n{len(FAILURES)} failure(s)")
sys.exit(1 if FAILURES else 0)
