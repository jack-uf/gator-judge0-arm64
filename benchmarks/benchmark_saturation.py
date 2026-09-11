#!/usr/bin/env python3
"""Concurrency saturation sweep: find out what stops throughput scaling.

The report used to end with "throughput rises to a knee near concurrency 25 and
then degrades, cause not attributed". This harness is that attribution. It
walks a concurrency ladder and, at every level, measures not just requests per
second but the state of every part of the machine that could be the limiter:
CPU (VM-wide, per core and per container), memory, swap, disk, context
switches, PostgreSQL, Redis, the Resque pool, and the sandbox itself.

Two sweeps are run, and the pair is the point:

  cold  every request carries a distinct source, so every request compiles
  hit   every request is byte-identical, so every request after the first is a
        compilation-cache hit

The cold sweep is what a classroom burst looks like. The hit sweep is the
control: it deletes the compiler from the workload, so if throughput saturates
both times at the same place the limiter is in the plumbing (worker pool,
API threads, database, sandbox setup) rather than in the compiler.

A third sweep is not part of the ladder at all. `parallel` runs N concurrent
g++ compiles directly in the worker container, with and without the
precompiled header, outside Judge0 -- Isolate, Resque, the API, Postgres and
Redis are all absent. It answers a question the ladder cannot: what does this
host do to per-compile cost as parallel compiles go from 1 to beyond the pool
size? One level is one `docker exec` that starts its compilers in the
background, waits for each of them, and reads its own accumulated child CPU, so
the CPU per compile is the compiler's cost with no reactor, queue or sandbox in
the figure. The two arms differ by exactly one argument (`-I/usr/local/pch/c++`,
the flag the C++ language row passes when the manifest is installed); nothing is
switched off inside the image, so nothing has to be restarted and restored
between arms, and the pair of them is itself the evidence that the header is
engaged -- an arm that came out the same as the other would mean it was not.
Every level compiles the same number of files, so a level's CPU is one unit of
work however it is split (see `--par-compiles`).

The load generator runs inside the compose network (benchmarks/loadgen.rb),
because a client on the Mac pays for Docker Desktop's port forwarder.

Honesty notes that matter when reading the output:

* Every level is time-stamped against the macOS host's `uptime` load averages,
  the only host figure this sandbox can read without privileges. This box is a
  12-vCPU Docker Desktop VM on a 12-core (6P + 6E) M3 Pro that is doing other
  work, so host load is recorded per level and a level can be discounted when
  the Mac was busy. The ladder opens and closes at concurrency 25, so drift
  against the first measurement shows up as a difference between the two.
* CPU per submission is a difference of the worker container's cgroup counters
  around the level, so it includes the Resque workers, Isolate and the compile
  -- the number a VPS has to be sized against -- and it includes this harness's
  own samplers, whose cost is calibrated at startup and reported under
  `preflight`. It excludes the load generator, which has its own container and
  reports its own CPU.
* "Simultaneous compilers", "simultaneous executions" and "isolate invocations"
  are sampled at SAMPLE_INTERVAL_S, so they are sampled peaks and floors, not
  exact extremes. The samplers see process names, not sandbox ids: `ps` here
  truncates the argument list before isolate's `-b <box>` appears, so the record
  counts isolate processes instead of distinct boxes.
* `CONFIG RESETSTAT` runs on Redis at the start of every level, so the command
  counters and latency percentiles read after it describe that level alone.
  Nothing is reset in PostgreSQL: its figures are read twice and differenced.

Usage:

    python3 benchmarks/benchmark_saturation.py --label sat
    python3 benchmarks/benchmark_saturation.py --label sat_probe --levels 4 --total 20 --sweeps cold
    python3 benchmarks/benchmark_saturation.py --label sat_parallel --sweeps parallel

It needs the Docker socket, so run it unsandboxed: it shells out to `docker
exec`, `docker cp` and `docker create`.

One sampler line per tick, space separated. The field order is the contract and
the tuples below name it. A group whose command failed is simply absent, and a
short line is reported as such rather than silently shifting the groups after
it -- the modes emit different groups, so no two of them share a layout:

    PS_FIELDS     worker container only, from `ps -e`
    CG_FIELDS     every container, from cgroup v2 and the VM's /proc/stat
    VM_FIELDS     worker container only, from the VM's /proc
    REDIS_FIELDS  the redis container only, from redis-cli
"""

import argparse
import base64
import json
import os
import random
import statistics
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from benchmark_pch import (  # noqa: E402  (path insert has to come first)
    CONTAINER,
    CPP,
    ROOT,
    SHAPES,
    assert_worker_is_clean,
    percentile,
    worker_cpu_usec,
)

CONTAINERS = {
    "worker": CONTAINER,
    "server": "native_judge0-server-1",
    "db": "native_judge0-db-1",
    "redis": "native_judge0-redis-1",
}
NETWORK = "native_judge0_default"
IMAGE = "judge0:arm64-native"
# POST /submissions?wait=true answers 201 Created, not 200: the row is created and
# then waited on. Nothing else is this API's contract, so the harness accepts 201
# exactly rather than a 2xx envelope -- a 200 or a 202 here means the server is
# answering something we did not ask for, and it should be loud.
HTTP_ACCEPTED = 201
LOADGEN_NAME = "judge0-saturation-loadgen"
LOADGEN_DIR = "/tmp"
WORK_DIR = Path("/private/tmp/judge0-sat")
SAMPLE_INTERVAL_S = 0.25
# The compiler the C++ language row actually runs, and the directory the PCH
# gate offers on the include path (app/services/pch.rb). Both are asserted in
# preflight: a probe that measured a different compiler would be worthless.
GXX = "/usr/local/gcc-9.2.0/bin/g++"
PCH_DIR = "/usr/local/pch/c++"

# Concurrency 25 opens and closes the ladder: both ends measure the same thing,
# so the pair bounds how much the host drifted during the sweep.
DEFAULT_LEVELS = [25, 1, 2, 4, 8, 16, 32, 50, 75, 100, 25]
# Parallel compiles per level for the direct g++ probe: around the 12-worker
# pool and past it.
PARALLEL_LEVELS = [1, 2, 4, 6, 8, 12, 16, 24]


def requests_for_level(concurrency):
    """Small levels are given fewer requests; at concurrency 1 a cold compile is
    ~0.25 s, so 200 requests would be a minute of measuring nothing new."""
    return 200 if concurrency >= 8 else max(30, concurrency * 12)


PS_FIELDS = (
    "procs", "compilers", "runs", "ruby", "resque_processing", "resque_waiting",
    "isolate_procs",
)
CG_FIELDS = (
    "uptime_s", "cpu_usec", "user_usec", "system_usec", "nr_throttled",
    "memory_current", "pids_current", "psi_cpu_us", "psi_mem_us", "psi_io_us",
    "procs_running", "procs_blocked", "processes", "ctxt",
)
VM_FIELDS = (
    "mem_available_kib", "swap_free_kib", "load1", "load5", "load15",
    "pgmajfault", "pswpin", "pswpout", "read_sectors", "write_sectors",
    "psi_vm_cpu_us", "core_busy", "core_total", "vm_busy", "vm_total",
)
REDIS_FIELDS = ("queue_depth", "redis_workers", "blocked_clients")

FIELD_GROUPS = {
    "ps": PS_FIELDS,
    "cg": CG_FIELDS,
    "vm": VM_FIELDS,
    "redis": REDIS_FIELDS,
}
# Which groups each sampler emits, in this order. The mode also decides what its
# container can run: only the worker image has `ps`, and only the redis
# container has `redis-cli`.
MODE_GROUPS = {
    "worker": ("ps", "cg", "vm"),
    "redis": ("cg", "redis"),
    "light": ("cg",),
}


SAMPLER = r"""
# Every numeric slot below is printed with a float format, never `%d`. The
# container's mawk clamps `%d` at 2^31 -- it prints 2147483647 for 2204619978,
# which is what /proc/pressure/cpu already reports on this VM -- and cgroup usec
# counters, PSI totals, /proc/diskstats sectors and per-process RSS all pass that
# bound on a machine that stays up. `%.0f` is exact to 2^53 and prints `0` for an
# unset variable, so a slot is never empty: an empty token silently shifts every
# field after it, which is how this harness first mis-read the VM group.
# Groups are joined by the shell printf at the bottom of the loop, which emits the
# separator between them; the awk blocks add no leading or trailing separator.
# `ps` is only trusted for what it cannot truncate: this image's procps-ng 3.3.17
# shrinks the `args` column to the output width, and neither `-ww` nor `--width`
# nor COLUMNS widens it (measured: 27 characters of args at three columns). A real
# submission's `-b <box>` sits ~250 characters into isolate's argv, behind thirteen
# `-E` flags, so it is never visible here -- the fields below come from `comm`,
# which ps never truncates, or from an args prefix shorter than that window. There
# is deliberately no box count and no per-process RSS sum: `boxes` cannot be
# observed through ps, and summing per-process RSS counts shared pages once per
# process (1404 MiB summed against 1206 MiB of memory.current on the same
# processes), while the worker group reports the cgroup's exact memory.current.
SAT_SAMPLER=1
log=__LOG__
stop=__STOP__
end=$(( $(date +%s) + __LIMIT__ ))
: > "$log"
while [ ! -e "$stop" ] && [ "$(date +%s)" -lt "$end" ]; do
  psf=$(ps -e -o comm=,args= 2>/dev/null | awk '
    /SAT_SAMPLER|SAT_PROBE|ps -e -o|OFS=/ { next }
    { n++;
      if ($1 == "cc1plus" || $1 == "cc1" || $1 == "as" || $1 == "ld" || $1 == "collect2" || $1 == "g++" || $1 == "gcc") comp++;
      if ($1 == "a.out") runs++;
      if ($1 == "ruby" || $1 == "ruby3.0") ruby++;
      if ($0 ~ /isolate\.bin/) iso++;
      if ($0 ~ /resque-.*: Processing/) busy++;
      if ($0 ~ /resque-.*: Waiting/) idle++;
    }
    END { printf "%d %d %d %d %d %d %d", n, comp, runs, ruby, busy, idle, iso }
  ')
  cg=$(awk -v OFS=" " '
    FILENAME ~ /uptime$/ { t = $1 }
    FILENAME ~ /cpu\.stat$/ && $1 == "usage_usec" { use = $2 }
    FILENAME ~ /cpu\.stat$/ && $1 == "user_usec" { usr = $2 }
    FILENAME ~ /cpu\.stat$/ && $1 == "system_usec" { sys = $2 }
    FILENAME ~ /cpu\.stat$/ && $1 == "nr_throttled" { thr = $2 }
    FILENAME ~ /memory\.current$/ { mem = $1 }
    FILENAME ~ /pids\.current$/ { pids = $1 }
    FILENAME ~ /cpu\.pressure$/ && $1 == "some" { split($0, x, "total="); split(x[2], y, " "); psc = y[1] }
    FILENAME ~ /memory\.pressure$/ && $1 == "some" { split($0, x, "total="); split(x[2], y, " "); psm = y[1] }
    FILENAME ~ /io\.pressure$/ && $1 == "some" { split($0, x, "total="); split(x[2], y, " "); psi = y[1] }
    FILENAME ~ /stat$/ && $1 == "procs_running" { run = $2 }
    FILENAME ~ /stat$/ && $1 == "procs_blocked" { blk = $2 }
    FILENAME ~ /stat$/ && $1 == "processes" { proc = $2 }
    FILENAME ~ /stat$/ && $1 == "ctxt" { ctx = $2 }
    END { printf "%.2f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f", t, use, usr, sys, thr, mem, pids, psc, psm, psi, run, blk, proc, ctx }
  ' /proc/uptime /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.current /sys/fs/cgroup/pids.current \
    /sys/fs/cgroup/cpu.pressure /sys/fs/cgroup/memory.pressure /sys/fs/cgroup/io.pressure /proc/stat \
    2>/dev/null)
  vmf=""
  case "__MODE__" in
    worker) vmf=$(awk -v OFS=" " '
      FILENAME ~ /meminfo$/ { if ($1 == "MemAvailable:") ma = $2; if ($1 == "SwapFree:") sf = $2 }
      FILENAME ~ /loadavg$/ { l1 = $1; l5 = $2; l15 = $3 }
      FILENAME ~ /diskstats$/ { rd += $6; wr += $10 }
      FILENAME ~ /vmstat$/ { if ($1 == "pgmajfault") mf = $2; if ($1 == "pswpin") si = $2; if ($1 == "pswpout") so = $2 }
      FILENAME ~ /pressure\/cpu$/ && $1 == "some" { split($0, x, "total="); split(x[2], y, " "); pc = y[1] }
      FILENAME ~ /\/proc\/stat$/ {
        if ($1 ~ /^cpu[0-9]+$/) {
          cores++;
          busy[cores] = $2 + $3 + $4 + $7 + $8 + $9;
          tot[cores] = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9;
          vmb += busy[cores]; vmt += tot[cores];
        }
      }
      END { b = ""; t = ""; for (i = 1; i <= cores; i++) { b = b (b == "" ? "" : ",") busy[i]; t = t (t == "" ? "" : ",") tot[i] }
            printf "%.0f %.0f %.2f %.2f %.2f %.0f %.0f %.0f %.0f %.0f %.0f %s %s %.0f %.0f", ma, sf, l1, l5, l15, mf, si, so, rd, wr, pc, b, t, vmb, vmt }
    ' /proc/meminfo /proc/loadavg /proc/diskstats /proc/vmstat /proc/pressure/cpu /proc/stat 2>/dev/null)
    ;;
  esac
  rf=""
  case "__MODE__" in
    redis)
      q=$(redis-cli -a judge0 --no-auth-warning LLEN resque:queue:default 2>/dev/null)
      w=$(redis-cli -a judge0 --no-auth-warning SCARD resque:workers 2>/dev/null)
      b=$(redis-cli -a judge0 --no-auth-warning INFO clients 2>/dev/null | tr -d '\r' | awk -F: '/^blocked_clients/{print $2}')
      rf=" ${q:-0} ${w:-0} ${b:-0}"
      ;;
  esac
  case "__MODE__" in
    worker) printf '%s %s %s%s\n' "$psf" "$cg" "$vmf" "$rf" ;;
    redis) printf '%s%s\n' "$cg" "$rf" ;;
    *) printf '%s\n' "$cg" ;;
  esac >> "$log"
  sleep __IV__
done
"""


def docker(*args, check=True, timeout=None, capture=True):
    out = subprocess.run(["docker", *args], capture_output=capture, text=True, timeout=timeout)
    if check and out.returncode != 0:
        detail = (out.stderr or "").strip() or (out.stdout or "").strip()
        raise RuntimeError(f"docker {' '.join(args)} failed with {out.returncode}: {detail}")
    return out


def sh(container, script, timeout=180):
    """docker exec, but the failure is loud and names the container."""
    return docker("exec", "-u", "root", container, "sh", "-c", script, timeout=timeout).stdout


def redis_cli(*args, timeout=60):
    return sh(CONTAINERS["redis"], "redis-cli -a judge0 --no-auth-warning " + " ".join(args), timeout=timeout)


def psql(queries, timeout=90):
    """Run SELECTs, one -A -t -F '|' result row per line.

    Every statement is quoted for the /bin/sh inside the container that receives
    it, including any quote the SQL itself contains. Writing `-c '<sql>'` and
    leaving it at that is what made `where state = 'active'` reach Postgres as
    `where state = active` -- an identifier, and an error -- and what would
    silently mangle the timestamp literal the level query filters on.
    """
    flags = " ".join(f"-c {shell_quote(query)}" for query in queries)
    return sh(CONTAINERS["db"], f"psql -U judge0 -d judge0 -A -t -F '|' {flags}", timeout=timeout)


def shell_quote(text):
    """One literal argument for /bin/sh: close the quote, escape a quote, open it
    again. Nothing else survives POSIX single quoting."""
    return "'" + text.replace("'", "'\\''") + "'"


def rows_of(text, columns):
    """psql -A -t -F '|' output into dicts, NULLs kept as None."""
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        values = line.split("|")
        rows.append({name: (None if value == "" else value) for name, value in zip(columns, values)})
    return rows


def host_load():
    """macOS load average: the only host figure this sandbox can read."""
    text = subprocess.run(["uptime"], capture_output=True, text=True, timeout=10).stdout
    tail = text.split("load averages:")[-1].split("load average:")[-1].split()
    return {"load1": float(tail[0]), "load5": float(tail[1]), "load15": float(tail[2])}


def tagged_source(source, tag, index):
    """Fixed width, so every level compiles the same bytes it did last time, and
    tagged with this run's own marker, so nothing here can land on a cache key an
    earlier benchmark already warmed -- a cold sweep that silently hit the
    compilation cache would report the fast path as the compile."""
    return f"{source}// sat{tag} {index:04d}\n"


def coerce(token):
    if token is None:
        return None
    try:
        return float(token)
    except ValueError:
        if "," in token:
            try:
                return [float(part) for part in token.split(",")]
            except ValueError:
                return token
        return token


def parse_sample(mode, line):
    """Positional, because that is what the sampler prints; the module docstring
    is the contract. A line that is short for its mode is flagged, so a group
    that failed cannot be read as a plausible value in the group after it."""
    tokens = line.split()
    row = {"_tokens": len(tokens)}
    index = 0
    for group in MODE_GROUPS[mode]:
        for field in FIELD_GROUPS[group]:
            row[field] = coerce(tokens[index]) if index < len(tokens) else None
            index += 1
    row["_short"] = index > len(tokens)
    return row


class Sampler:
    """A sampling loop that lives inside a container, read back after the level.

    It writes its own log and exits when a stop file appears, instead of being a
    `docker exec` client whose stdout this process reads: a client killed by a
    harness crash leaves the shell loop running inside the container, and a
    leftover sampler burns CPU that the next level's cgroup difference would
    report as submission cost. The time bound in the script is the safety net for
    a harness that dies before it can create the stop file.
    """

    def __init__(self, container, mode, interval=SAMPLE_INTERVAL_S, limit_s=1800):
        self.container = container
        self.mode = mode
        self.interval = interval
        self.limit_s = limit_s
        stamp = f"{os.getpid()}.{container}.{mode}"
        self.log = f"/tmp/judge0_sat_sampler.{stamp}.log"
        self.stop_path = f"/tmp/judge0_sat_sampler.{stamp}.stop"
        self.rows = []
        self.error = None

    def start(self):
        script = (SAMPLER
                  .replace("__LOG__", self.log)
                  .replace("__STOP__", self.stop_path)
                  .replace("__MODE__", self.mode)
                  .replace("__IV__", str(self.interval))
                  .replace("__LIMIT__", str(self.limit_s)))
        sh(self.container, f"rm -f {self.log} {self.stop_path}")
        docker("exec", "-u", "root", "-d", self.container, "sh", "-c", script)

    def stop(self):
        """Touch the stop file, then read what the loop wrote. Nothing here is
        fatal on its own: a level that lost its sampler still has the load
        generator's numbers, and the level record says which part is missing."""
        try:
            sh(self.container, f"touch {self.stop_path}")
            time.sleep(0.3)
            text = sh(self.container, f"cat {self.log} 2>/dev/null || true")
            sh(self.container, f"rm -f {self.log} {self.stop_path}")
        except (RuntimeError, subprocess.SubprocessError) as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            return self.rows
        for line in text.splitlines():
            if line.strip():
                self.rows.append(parse_sample(self.mode, line))
        return self.rows

    def summary(self):
        return {
            group: summarise_fields(self.rows, FIELD_GROUPS[group])
            for group in MODE_GROUPS[self.mode]
        }


def summarise_fields(rows, fields):
    """first/last/min/max/mean per field, plus what the samples themselves say
    about coverage. List-valued fields (per-core jiffies) keep raw first/last."""
    out = {}
    for field in fields:
        values = [row[field] for row in rows if isinstance(row.get(field), (int, float))]
        lists = [row[field] for row in rows if isinstance(row.get(field), list)]
        entry = {}
        if values:
            entry = {
                "first": values[0],
                "last": values[-1],
                "min": min(values),
                "max": max(values),
                "mean": round(statistics.mean(values), 3),
                "n": len(values),
            }
        elif lists:
            entry = {"first": lists[0], "last": lists[-1], "n": len(lists)}
        if entry:
            out[field] = entry
    if rows:
        out["_samples"] = {"n": len(rows), "short": sum(1 for row in rows if row.get("_short"))}
    return out


def counter_delta(group, field):
    """last - first of a monotone counter, or None when the samples are missing."""
    entry = group.get(field)
    if not entry or "first" not in entry:
        return None
    return entry["last"] - entry["first"]


def psi_percent(group, field, wall_s):
    """Share of the level's wall time during which at least one task was stalled
    on that resource. PSI 'some' accumulates stall time, not task-seconds."""
    stalled_us = counter_delta(group, field)
    if stalled_us is None or not wall_s:
        return None
    return round(stalled_us / (wall_s * 1e6) * 100, 3)


def worker_metrics(sampler_summary, wall_s):
    cg = sampler_summary.get("cg", {})
    cpu_usec = counter_delta(cg, "cpu_usec")
    user_usec = counter_delta(cg, "user_usec")
    system_usec = counter_delta(cg, "system_usec")
    memory = cg.get("memory_current", {}).get("max")
    return {
        "cpu_ms": round(cpu_usec / 1000, 1) if cpu_usec is not None else None,
        "user_ms": round(user_usec / 1000, 1) if user_usec is not None else None,
        "system_ms": round(system_usec / 1000, 1) if system_usec is not None else None,
        "throttled_periods": counter_delta(cg, "nr_throttled"),
        "psi_cpu_some_pct": psi_percent(cg, "psi_cpu_us", wall_s),
        "psi_memory_some_pct": psi_percent(cg, "psi_mem_us", wall_s),
        "psi_io_some_pct": psi_percent(cg, "psi_io_us", wall_s),
        "memory_peak_mib": round(memory / 1024 / 1024, 1) if memory else None,
        "pids_peak": cg.get("pids_current", {}).get("max"),
        "runqueue_max": cg.get("procs_running", {}).get("max"),
        "procs_blocked_max": cg.get("procs_blocked", {}).get("max"),
    }


def vm_metrics(sampler_summary, wall_s):
    """What the whole VM was doing. /proc inside a container is the VM's, so this
    is the machine Judge0 shares with Docker Desktop -- the quantity that has to
    run out for the knee to be a CPU knee."""
    vm = sampler_summary.get("vm", {})
    cg = sampler_summary.get("cg", {})
    busy_first = vm.get("core_busy", {}).get("first") or []
    busy_last = vm.get("core_busy", {}).get("last") or []
    total_first = vm.get("core_total", {}).get("first") or []
    total_last = vm.get("core_total", {}).get("last") or []
    cores = len(busy_first)
    per_core = []
    for index in range(min(cores, len(busy_last), len(total_first), len(total_last))):
        total = total_last[index] - total_first[index]
        if total > 0:
            per_core.append(round((busy_last[index] - busy_first[index]) / total * 100, 1))
    busy = counter_delta(vm, "vm_busy")
    total = counter_delta(vm, "vm_total")
    return {
        "cores": cores or None,
        "cpu_busy_pct": round(busy / total * 100, 1) if busy is not None and total else None,
        # Average number of cores holding a runnable task, from per-core jiffies.
        "cores_busy_mean": round(busy / total * cores, 2) if busy is not None and total and cores else None,
        "per_core_busy_pct": per_core,
        "cores_over_80pct": sum(1 for value in per_core if value >= 80),
        "runqueue_max": cg.get("procs_running", {}).get("max"),
        "psi_cpu_some_pct": psi_percent(vm, "psi_vm_cpu_us", wall_s),
        "load1_max": vm.get("load1", {}).get("max"),
        "mem_available_min_mib": round(vm.get("mem_available_kib", {}).get("min", 0) / 1024, 1)
        if vm.get("mem_available_kib") else None,
        "swap_free_min_mib": round(vm.get("swap_free_kib", {}).get("min", 0) / 1024, 1)
        if vm.get("swap_free_kib") else None,
        "swap_in_pages": counter_delta(vm, "pswpin"),
        "swap_out_pages": counter_delta(vm, "pswpout"),
        "major_faults": counter_delta(vm, "pgmajfault"),
        "disk_read_sectors": counter_delta(vm, "read_sectors"),
        "disk_write_sectors": counter_delta(vm, "write_sectors"),
        "context_switches": counter_delta(vm, "ctxt") or counter_delta(cg, "ctxt"),
        "forks": counter_delta(cg, "processes"),
    }


def sandbox_metrics(sampler_summary):
    """What the sandbox layer was doing, from process names alone -- see the `ps`
    note above SAMPLER for why there is no box count and no RSS field here.
    `isolate_procs_max` is the isolate invocations alive at once, two per in-flight
    submission, so it is the concurrency the sandbox itself actually carried."""
    ps = sampler_summary.get("ps", {})
    redis = sampler_summary.get("redis", {})
    return {
        "compilers_max": ps.get("compilers", {}).get("max"),
        "runs_max": ps.get("runs", {}).get("max"),
        "isolate_procs_max": ps.get("isolate_procs", {}).get("max"),
        "resque_processing_max": ps.get("resque_processing", {}).get("max"),
        "resque_waiting_max": ps.get("resque_waiting", {}).get("max"),
        "ruby_procs_max": ps.get("ruby", {}).get("max"),
        "procs_max": ps.get("procs", {}).get("max"),
        "redis_queue_depth_max": redis.get("queue_depth", {}).get("max"),
        "redis_workers": redis.get("redis_workers", {}).get("max"),
        "redis_blocked_clients_max": redis.get("blocked_clients", {}).get("max"),
    }


REDIS_COUNTERS = (
    "total_commands_processed", "total_net_input_bytes", "total_net_output_bytes",
    "keyspace_hits", "keyspace_misses", "expired_keys", "total_connections_received",
    "instantaneous_ops_per_sec",
)


def redis_info(section):
    info = {}
    for line in redis_cli("INFO", section).replace("\r", "").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        info[key] = value
    return info


def redis_percentiles(info):
    out = {}
    for key, value in info.items():
        if not key.startswith("latency_percentiles_usec_"):
            continue
        parts = dict(pair.split("=", 1) for pair in value.split(",") if "=" in pair)
        if float(parts.get("p50", 0)) <= 0 and float(parts.get("p99", 0)) <= 0:
            continue
        out[key[len("latency_percentiles_usec_"):]] = {
            name.replace(".", "dot"): round(float(number), 3) for name, number in parts.items()
        }
    return out


def redis_command_stats(info):
    out = {}
    for key, value in info.items():
        if not key.startswith("cmdstat_"):
            continue
        parts = dict(pair.split("=", 1) for pair in value.split(",") if "=" in pair)
        calls = int(float(parts.get("calls", 0)))
        if calls <= 0:
            continue
        usec = float(parts.get("usec", 0))
        out[key[len("cmdstat_"):]] = {
            "calls": calls,
            "usec": round(usec, 1),
            "usec_per_call": round(usec / calls, 3),
        }
    return out


def redis_level_stats():
    """What Redis did during the level. RESETSTAT ran when the level started, so
    these counters are the level's own rather than the server's lifetime."""
    stats = redis_info("stats")
    commands = redis_command_stats(redis_info("commandstats"))
    busiest = sorted(commands.items(), key=lambda item: -item[1]["usec"])[:8]
    return {
        "counters": {key: stats.get(key) for key in REDIS_COUNTERS if key in stats},
        "commands_total": sum(entry["calls"] for entry in commands.values()),
        "busiest_commands": {name: entry for name, entry in busiest},
        "latency_percentiles_usec": redis_percentiles(redis_info("latencystats")),
    }


PG_STATS_COLUMNS = (
    "xact_commit", "xact_rollback", "blks_read", "blks_hit", "tup_returned",
    "tup_fetched", "tup_inserted", "tup_updated", "tup_deleted", "deadlocks",
    "conflicts", "temp_bytes",
)


def db_state():
    stats = rows_of(psql([
        "select " + ", ".join(PG_STATS_COLUMNS) + " from pg_stat_database where datname = current_database()"
    ]), PG_STATS_COLUMNS)
    activity = rows_of(psql([
        "select count(*), count(*) filter (where wait_event_type is not null), "
        "count(*) filter (where state = 'active') from pg_stat_activity where datname = current_database()"
    ]), ("connections", "waiting", "active"))
    return {
        "stats": {name: int(value) for name, value in (stats[0] if stats else {}).items() if value is not None},
        "activity": {name: int(value) for name, value in (activity[0] if activity else {}).items() if value is not None},
    }


def db_mark():
    rows = rows_of(psql(["select now()::text"]), ("now",))
    return rows[0]["now"] if rows else None


def db_level(mark):
    """Where the level's submissions spent their time, straight out of the table:
    the queue wait is `started_at - created_at`, which is the half of the wall
    time the API's own latency figures cannot see. The created_at spread is the
    API's admission window: with `wait=true` a submission holds a Puma thread for
    its whole life, so a level whose requests were created long after they were
    sent was waiting for a thread, not for a compiler."""
    columns = ("submissions", "started", "finished", "queue_wait_avg_s",
               "queue_wait_max_s", "total_avg_s", "total_max_s", "created_spread_s")
    sql = (
        "select count(*), count(started_at), count(finished_at), "
        "coalesce(round(avg(extract(epoch from started_at - created_at))::numeric, 4), -1), "
        "coalesce(round(max(extract(epoch from started_at - created_at))::numeric, 4), -1), "
        "coalesce(round(avg(extract(epoch from finished_at - created_at))::numeric, 4), -1), "
        "coalesce(round(max(extract(epoch from finished_at - created_at))::numeric, 4), -1), "
        "coalesce(round(extract(epoch from max(created_at) - min(created_at))::numeric, 4), -1) "
        "from submissions where created_at > timestamp '" + mark + "'"
    )
    rows = rows_of(psql([sql]), columns)
    row = rows[0] if rows else {}
    out = {}
    for name, value in row.items():
        if value is None:
            out[name] = None
        elif name in ("submissions", "started", "finished"):
            out[name] = int(value)
        else:
            out[name] = float(value)
    return out


def db_delta(before, after):
    delta = {}
    for name, value in after["stats"].items():
        previous = before["stats"].get(name)
        if previous is not None:
            delta[name] = value - previous
    return delta


def calibrate_sampler_cpu(window_s=10.0):
    """CPU the sampling machinery itself costs, measured while nothing else runs.
    Worker CPU is a cgroup difference, so this is inside every level's figure;
    knowing its size is what keeps the report honest about its own overhead."""
    before = worker_cpu_usec()
    sampler = Sampler(CONTAINER, "worker")
    sampler.start()
    time.sleep(window_s)
    rows = sampler.stop()
    after = worker_cpu_usec()
    error = sampler.error
    return {
        "window_s": window_s,
        "cpu_ms": round((after - before) / 1000.0, 1),
        "samples": len(rows),
        "sampler_error": error,
    }


def pch_probe():
    """Does `-I/usr/local/pch/c++` actually make GCC read the PCH? A flag mismatch
    (different -O, standard or feature flags) makes GCC rebuild the headers and
    ignore the .gch silently, so the probe asserts what the measurements assume
    instead of trusting the file's presence."""
    source = "/tmp/judge0_sat_pch_probe.cpp"
    script = (
        f"printf '#include <iostream>\\nint main() {{ return 0; }}\\n' > {source}; "
        f"{GXX} -O0 -pipe {source} -I{PCH_DIR} -H -o /tmp/judge0_sat_pch_probe.out 2>&1 "
        "| grep -c 'gch'; "
        "rm -f " + source + " /tmp/judge0_sat_pch_probe.out"
    )
    engaged = sh(CONTAINER, script).strip()
    return {"iostream_gch_lines": int(engaged or 0), "engaged": bool(int(engaged or 0))}


def resolve_driver_ruby():
    """ruby is at /usr/bin/ruby in the image, but the driver's entrypoint is found
    once and recorded rather than assumed: a wrong entrypoint would look like a
    network failure."""
    out = docker("run", "--rm", "--network", NETWORK, "--entrypoint", "sh", IMAGE,
                 "-c", "command -v ruby || echo missing", check=False)
    return (out.stdout or "").strip() or "missing"


def stray_samplers(container):
    """How many sampler loops an interrupted run left behind in this container.
    The scan skips its own pid: the script that looks for `SAT_SAMPLER` contains
    the word, so without that it finds itself and reports one every time."""
    script = (
        'me=$$; n=0; for p in /proc/[0-9]*; do pid=${p#/proc/}; [ "$pid" = "$me" ] && continue; '
        'cmd=$(tr "\\0" " " < $p/cmdline 2>/dev/null); '
        'case "$cmd" in *SAT_SAMPLER*) n=$((n+1));; esac; done; echo $n'
    )
    return int(sh(container, script).strip() or 0)


def preflight():
    checks = {}
    running = set(docker("ps", "--format", "{{.Names}}").stdout.split())
    missing = sorted(set(CONTAINERS.values()) - running)
    if missing:
        raise SystemExit(
            "these containers are not running: " + ", ".join(missing)
            + "\nStart the stack with `docker compose up -d` from the fork root, then run this again."
        )
    checks["containers"] = sorted(CONTAINERS.values())
    strays = {name: count for name, count in
              ((name, stray_samplers(container)) for name, container in CONTAINERS.items()) if count}
    checks["stray_samplers"] = strays
    if strays:
        raise SystemExit(
            "a sampler loop from an interrupted run is still going in "
            + ", ".join(f"{name} ({count})" for name, count in sorted(strays.items()))
            + ".\nIt burns CPU that this run's cgroup differences would report as submission cost. "
            "Stop it with\n  docker exec -u root <container> pkill -f SAT_SAMPLER\n"
            "(`redis` has no pkill: `docker compose restart redis` stops it.)"
        )
    checks["gxx"] = sh(CONTAINER, f"readlink -f {GXX} 2>/dev/null || echo missing").strip()
    checks["gxx_version"] = sh(CONTAINER, f"{GXX} --version 2>/dev/null | head -1").strip()
    checks["clock_ticks"] = int(sh(CONTAINER, "getconf CLK_TCK 2>/dev/null || echo 100").strip() or 100)
    manifest = sh(CONTAINER, f"cat {PCH_DIR}/pch.sha256 2>/dev/null | wc -l").strip()
    checks["pch_manifest_entries"] = int(manifest or 0)
    checks["pch_offered"] = checks["pch_manifest_entries"] > 0
    checks["pch"] = pch_probe() if checks["pch_offered"] else {"engaged": False}
    checks["driver_ruby"] = resolve_driver_ruby()
    if checks["driver_ruby"] == "missing":
        raise SystemExit(f"{IMAGE} has no ruby, so benchmarks/loadgen.rb cannot run in it")
    checks["pg_extensions"] = [
        row["extname"] for row in rows_of(psql(["select extname from pg_extension order by 1"]), ("extname",))
    ]
    checks["redis_latency_tracking"] = redis_info("latencystats") != {}
    checks["idle_worker_cpu_ms_over_3s"] = round(assert_worker_is_clean(), 1)
    checks["sampler_cost"] = calibrate_sampler_cpu()
    checks["host"] = host_load()
    return checks


def summarize_rows(rows):
    accepted = [row for row in rows if row.get("code") == HTTP_ACCEPTED]
    latencies = sorted(row["ms"] for row in accepted if isinstance(row.get("ms"), (int, float)))
    # `time` and `memory` are what a submission response carries by default
    # (SubmissionSerializer.default_fields): the row's own `wall_time` column is
    # not in that list, so the driver would always read back nil for it.
    judge0_time = [float(row["time"]) for row in rows if row.get("time")]
    memories = [row["memory"] for row in rows if isinstance(row.get("memory"), (int, float))]
    return {
        "responses": len(rows),
        "http_accepted": len(accepted),
        "errors": [str(row.get("error"))[:200] for row in rows if row.get("error")][:10],
        "statuses": dict(Counter(row.get("status") or "?" for row in rows)),
        "latency_ms": {
            "p50": round(percentile(latencies, 0.50), 1),
            "p95": round(percentile(latencies, 0.95), 1),
            "p99": round(percentile(latencies, 0.99), 1),
            "mean": round(statistics.mean(latencies), 1) if latencies else None,
            "min": round(latencies[0], 1) if latencies else None,
            "max": round(latencies[-1], 1) if latencies else None,
        } if latencies else None,
        "judge0_time_s_mean": round(statistics.mean(judge0_time), 4) if judge0_time else None,
        "judge0_memory_kb_mean": round(statistics.mean(memories), 1) if memories else None,
        "submissions_with_error_field": sum(1 for row in rows if row.get("error_field")),
        "compile_output_seen": sum(
            1 for row in accepted if row.get("status") and row.get("time") is None
        ),
    }


def parse_loadgen(stdout):
    rows, meta, unparsed = [], None, []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            unparsed.append(line[:200])
            continue
        if isinstance(payload, dict) and "_meta" in payload:
            meta = payload["_meta"]
        else:
            rows.append(payload)
    return rows, meta, unparsed


def as_text(value):
    if value is None:
        return ""
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else value


def run_loadgen(concurrency, workload, timeout_s, ruby):
    """One container per level, created stopped so the driver and the workload can
    be copied in before it starts. `docker cp` rather than a bind mount: the
    workload then travels as a file, with no host directory sharing to configure
    and no way for the driver to write anything back."""
    docker("rm", "-f", LOADGEN_NAME, check=False)
    docker("create", "--name", LOADGEN_NAME, "--network", NETWORK, "--entrypoint", ruby, IMAGE,
           f"{LOADGEN_DIR}/loadgen.rb", "--url", "http://server:2358",
           "--workload", f"{LOADGEN_DIR}/workload.json", "--concurrency", str(concurrency))
    docker("cp", str(ROOT / "benchmarks" / "loadgen.rb"), f"{LOADGEN_NAME}:{LOADGEN_DIR}/loadgen.rb")
    docker("cp", str(workload), f"{LOADGEN_NAME}:{LOADGEN_DIR}/workload.json")
    failure = None
    try:
        out = docker("start", "-a", LOADGEN_NAME, timeout=timeout_s)
        stdout, exit_code = out.stdout, out.returncode
    except subprocess.TimeoutExpired as exc:
        stdout, exit_code = as_text(exc.stdout), None
        failure = f"the driver did not finish within {timeout_s}s"
    finally:
        docker("rm", "-f", LOADGEN_NAME, check=False)
    rows, meta, unparsed = parse_loadgen(stdout)
    return {"rows": rows, "meta": meta, "unparsed": unparsed, "exit_code": exit_code, "failure": failure}


SAMPLER_MODES = {"worker": "worker", "server": "light", "db": "light", "redis": "redis"}


def run_level(sweep, concurrency, total, tag, nonce, ruby):
    """One rung of the ladder: send `total` submissions at `concurrency`, with the
    whole machine sampled from before the first request until after the last."""
    source = SHAPES[1][1]["source_code"]
    stdin = SHAPES[1][1]["stdin"]
    if sweep == "cold":
        payloads = [
            {"language_id": CPP, "source_code": tagged_source(source, tag, nonce + index), "stdin": stdin}
            for index in range(total)
        ]
    else:
        payloads = [
            {"language_id": CPP, "source_code": tagged_source(source, tag, 0), "stdin": stdin}
            for _ in range(total)
        ]
    workload = WORK_DIR / f"workload_{sweep}_c{concurrency}.json"
    workload.write_text(json.dumps(payloads) + "\n")

    idle_cpu_ms = round(assert_worker_is_clean(), 1)
    samplers = {name: Sampler(container, SAMPLER_MODES[name]) for name, container in CONTAINERS.items()}
    summaries = {}

    def stop_samplers():
        """Called once on the normal path, and again from `finally` if anything
        above raised. A sampler loop that is left running keeps burning CPU, and
        the next level reads it as submission cost."""
        for name, sampler in samplers.items():
            if name in summaries:
                continue
            sampler.stop()
            summaries[name] = sampler.summary()
            if sampler.error:
                summaries[name]["error"] = sampler.error

    try:
        for sampler in samplers.values():
            sampler.start()
        time.sleep(1.0)
        host_before = host_load()
        worker_cpu_before = worker_cpu_usec()
        mark = db_mark()
        db_before = db_state()
        redis_cli("CONFIG", "RESETSTAT")

        host_started = time.perf_counter()
        result = run_loadgen(concurrency, workload, timeout_s=180 + total * 4, ruby=ruby)
        host_wall_s = round(time.perf_counter() - host_started, 3)

        worker_cpu_after = worker_cpu_usec()
        host_after = host_load()
        submissions = db_level(mark)
        db_after = db_state()
        redis = redis_level_stats()
        stop_samplers()
    finally:
        stop_samplers()

    meta = result["meta"] or {}
    driver_wall = meta.get("wall_s") or host_wall_s
    responses = summarize_rows(result["rows"])
    worker_cpu_ms = (worker_cpu_after - worker_cpu_before) / 1000.0
    worker_user_ms = (counter_delta(summaries["worker"].get("cg", {}), "user_usec") or 0) / 1000.0
    worker_system_ms = (counter_delta(summaries["worker"].get("cg", {}), "system_usec") or 0) / 1000.0
    sampler_worker_ms = (counter_delta(summaries["worker"].get("cg", {}), "cpu_usec") or 0) / 1000.0
    latency = responses["latency_ms"] or {}
    queue_ms = None if submissions.get("queue_wait_avg_s", -1) is None else submissions["queue_wait_avg_s"] * 1000
    total_ms = None if submissions.get("total_avg_s", -1) is None else submissions["total_avg_s"] * 1000
    phases_ms = {
        "client_mean": latency.get("mean"),
        "db_created_spread": None if submissions.get("created_spread_s") in (None, -1) else round(submissions["created_spread_s"] * 1000, 1),
        "queue_wait_mean": None if queue_ms is None or queue_ms < 0 else round(queue_ms, 1),
        "queue_wait_max": None if submissions.get("queue_wait_max_s", -1) in (None, -1) else round(submissions["queue_wait_max_s"] * 1000, 1),
        "execution_mean": None if total_ms is None or queue_ms is None or total_ms < 0 else round(total_ms - queue_ms, 1),
        "execution_max": None if submissions.get("total_max_s", -1) in (None, -1) else round(submissions["total_max_s"] * 1000, 1),
    }
    if phases_ms["client_mean"] is not None and total_ms is not None and total_ms >= 0:
        phases_ms["outside_submission_mean"] = round(phases_ms["client_mean"] - total_ms, 1)

    suspect = []
    if result["failure"]:
        suspect.append(result["failure"])
    if responses["http_accepted"] != total:
        suspect.append(
            f"{total - responses['http_accepted']} of {total} requests did not answer "
            f"{HTTP_ACCEPTED}"
        )
    if responses["statuses"] and set(responses["statuses"]) != {"Accepted"}:
        suspect.append(f"statuses were {responses['statuses']}")
    if responses["submissions_with_error_field"]:
        suspect.append(f"{responses['submissions_with_error_field']} responses carried an `error` field")
    if result["unparsed"]:
        suspect.append(f"{len(result['unparsed'])} driver output lines were not JSON")
    if meta and meta.get("requests") != total:
        suspect.append(f"the driver ran {meta.get('requests')} requests, not {total}")
    if submissions.get("submissions") is not None and submissions["submissions"] != total:
        suspect.append(
            f"PostgreSQL saw {submissions['submissions']} submissions for this level, not {total} "
            "(the create-window may have caught a straggler)"
        )
    if phases_ms.get("outside_submission_mean") is not None and phases_ms["outside_submission_mean"] < 0:
        suspect.append("client latency was below the submission's own database window")
    if sampler_worker_ms and abs(sampler_worker_ms - worker_cpu_ms) / worker_cpu_ms > 0.2:
        suspect.append(
            f"the sampler's own cgroup window saw {sampler_worker_ms:.0f} ms against "
            f"{worker_cpu_ms:.0f} ms for the load window"
        )
    for name, summary in summaries.items():
        short = sum(
            summary.get(group, {}).get("_samples", {}).get("short", 0)
            for group in MODE_GROUPS[SAMPLER_MODES[name]]
        )
        if short:
            # A short line means a field was missing, and every field after it is
            # read from the neighbour's slot. The numbers still parse, so this has
            # to fail loudly instead of producing a plausible-looking level.
            suspect.append(
                f"{name} sampler lines were short for {short} ticks, so its groups are "
                "misaligned and its fields are shifted; check the separator between groups "
                "in SAMPLER and re-run the level"
            )
    caveats = []
    if host_after["load1"] - host_before["load1"] > 3:
        caveats.append(
            f"the Mac's load average climbed from {host_before['load1']} to {host_after['load1']} during this level"
        )
    return {
        "sweep": sweep,
        "concurrency": concurrency,
        "total_requests": total,
        "driver_wall_s": driver_wall,
        "host_wall_s": host_wall_s,
        "throughput_req_per_s": round(total / driver_wall, 2) if driver_wall else None,
        "driver": {
            "exit_code": result["exit_code"],
            "cpu_ms": round(meta.get("driver_cpu_usec", 0) / 1000.0, 1),
            "cpu_ms_per_request": round(meta.get("driver_cpu_usec", 0) / 1000.0 / total, 3),
            "rows_seen": len(result["rows"]),
            "rows_missing": total - len(result["rows"]),
            "unparsed_lines": result["unparsed"],
        },
        "responses": responses,
        "phases_ms": phases_ms,
        "worker": {
            **worker_metrics(summaries["worker"], host_wall_s),
            "cpu_ms_total": round(worker_cpu_ms, 1),
            "cpu_ms_per_submission": round(worker_cpu_ms / total, 1),
            "user_ms_per_submission": round(worker_user_ms / total, 1),
            "system_ms_per_submission": round(worker_system_ms / total, 1),
            "sampler_window_cpu_ms": round(sampler_worker_ms, 1),
            "idle_cpu_ms_over_3s_before": idle_cpu_ms,
        },
        "vm": vm_metrics(summaries["worker"], host_wall_s),
        "sandbox": sandbox_metrics(summaries["worker"]),
        "other_containers": {
            name: {"cpu_ms": round((counter_delta(summary.get("cg", {}), "cpu_usec") or 0) / 1000.0, 1)}
            for name, summary in summaries.items() if name != "worker"
        },
        "db": {
            "submission_timing": submissions,
            "counters": db_delta(db_before, db_after),
            "activity": db_after["activity"],
        },
        "redis": redis,
        "host": {"before": host_before, "after": host_after},
        "samplers": summaries,
        "suspect": suspect,
        "caveats": caveats,
    }, nonce + (total if sweep == "cold" else 0)


def fmt(value, spec="{:.2f}", missing="-"):
    return missing if value is None else spec.format(value)


def print_row(record):
    worker = record["worker"]
    vm = record["vm"]
    sandbox = record["sandbox"]
    latency = record["responses"]["latency_ms"] or {}
    print(
        f"  {record['sweep']:5s} c={record['concurrency']:3d} "
        f"req/s={fmt(record['throughput_req_per_s'], '{:6.2f}')} "
        f"wall={fmt(record['driver_wall_s'], '{:6.1f}')}s "
        f"p50={fmt(None if latency.get('p50') is None else latency['p50'] / 1000, '{:5.2f}')}s "
        f"cpu/sub={fmt(worker['cpu_ms_per_submission'], '{:6.0f}')}ms "
        f"cores={fmt(vm['cores_busy_mean'], '{:4.1f}')}/{vm['cores'] or '-'} "
        f"runq={fmt(vm['runqueue_max'], '{:4.0f}')} "
        f"iso={fmt(sandbox['isolate_procs_max'], '{:3.0f}')} "
        f"qwait={fmt(None if record['phases_ms']['queue_wait_mean'] is None else record['phases_ms']['queue_wait_mean'] / 1000, '{:5.2f}')}s "
        f"drv={fmt(record['driver']['cpu_ms_per_request'], '{:5.2f}')}ms/req"
    )
    for reason in record["suspect"]:
        print(f"        suspect: {reason}")
    for reason in record["caveats"]:
        print(f"        caveat: {reason}")


# --- the direct compiler probe ------------------------------------------------
#
# The ladder can only say where end-to-end throughput stops scaling. This probe
# answers whether the compiler itself is why: N g++ runs at once, no Isolate, no
# Resque, no API, so the only thing being measured is the host's ability to run
# compilers in parallel.
#
# One `docker exec` per level, and the shell body below is why. A shell folds
# every reaped child's CPU into its own counters, which is what
# getrusage(RUSAGE_CHILDREN) reports and what `time` prints: so a shell that
# starts all N compilers and waits for each of them is itself a complete CPU
# meter for the level, with no sampler thread and no reading /proc from outside.
# `/proc/$$/stat` rather than `/proc/self/stat`, because the latter would be the
# awk that read it. Fields 14-17 are utime, stime, cutime, cstime.
#
# CLK_TCK is 100 in this image (preflight asserts it), so a tick is 10 ms: on a
# level that compiles 96 files the quantisation is 0.1 ms per compile. The
# container's cgroup is read around the same window as a cross-check, because a
# figure that the cgroup does not corroborate is a figure to distrust.
PROBE_SOURCE = SHAPES[1][1]["source_code"]
PROBE = r"""
SAT_PROBE=1
d=/tmp/judge0_sat_probe
rm -rf "$d"; mkdir -p "$d"
printf '%s' '__B64__' | base64 -d > "$d/base.cpp" || { echo 'SAT_PROBE base64 decode failed'; exit 1; }
i=1
while [ $i -le __M__ ]; do
  { cat "$d/base.cpp"; printf '// par__TAG__ n=__N__ arm=__ARM__ i=%04d\n' "$i"; } > "$d/s$i.cpp"
  i=$((i + 1))
done
ticks() { awk '{ sub(/^[^)]*\) /, ""); print $12 + $13 + $14 + $15 }' "/proc/$$/stat"; }
t0=$(date +%s.%N)
before=$(ticks)
pids=''
# __M__ files over __N__ slots, so every level compiles the same number of files
# and every slot compiles the same fraction of them.
slot=1
while [ $slot -le __N__ ]; do
  (
    f=0
    j=$slot
    while [ $j -le __M__ ]; do
      __GXX__ -O0 -pipe __INC__ "$d/s$j.cpp" -o "$d/s$j.out" >/dev/null 2>"$d/s$j.err" || f=$((f + 1))
      j=$((j + __N__))
    done
    echo "$f" > "$d/f$slot"
  ) &
  pids="$pids $!"
  slot=$((slot + 1))
done
failed=0
for p in $pids; do wait "$p" || failed=$((failed + 1)); done
for f in "$d"/f*; do failed=$((failed + $(cat "$f"))); done
after=$(ticks)
t1=$(date +%s.%N)
rm -rf "$d"
printf 'SAT_PROBE n=%s arm=%s before=%s after=%s t0=%s t1=%s failed=%s\n' '__N__' '__ARM__' "$before" "$after" "$t0" "$t1" "$failed"
"""


def compiles_for_level(parallel, target):
    """The same work at every level, and a multiple of the level's width, so each
    compiler in a level compiles the same number of files. A level that did less
    work would come out faster for the wrong reason."""
    return max(parallel, ((target + parallel - 1) // parallel) * parallel)


def compile_probe(parallel, compiles, arm, tag, ticks_per_s):
    """One level of the probe: `compiles` files compiled `parallel` at a time,
    `arm` deciding whether the precompiled header is on the include path."""
    script = (
        PROBE
        .replace("__B64__", base64.b64encode(PROBE_SOURCE.encode()).decode())
        .replace("__GXX__", GXX)
        .replace("__INC__", f"-I{PCH_DIR}" if arm == "pch" else "")
        .replace("__TAG__", str(tag))
        .replace("__ARM__", arm)
        .replace("__N__", str(parallel))
        .replace("__M__", str(compiles))
    )
    out = sh(CONTAINER, script, timeout=900)
    for line in out.splitlines():
        if not line.startswith("SAT_PROBE "):
            continue
        field = dict(part.split("=", 1) for part in line.split()[1:])
        ticks = int(field["after"]) - int(field["before"])
        wall_s = float(field["t1"]) - float(field["t0"])
        return {
            "parallel": parallel,
            "arm": arm,
            "wall_s": round(wall_s, 3),
            "cpu_ticks": ticks,
            "cpu_ms_total": round(ticks * 1000.0 / ticks_per_s, 1),
            "started_before": field["t0"],
            "finished_after": field["t1"],
            "failed_compiles": int(field["failed"]),
        }
    raise RuntimeError(
        f"the {arm} probe at {parallel} way parallelism printed no result line, so it did not "
        f"reach the end of its own script. Output was:\n{out.strip()[:2000]}"
    )


def run_parallel_sweep(levels, reps, target, tag, ticks_per_s):
    """Every level, every arm, `reps` times over."""
    # `assert_worker_is_clean` is the idle gate, and it is calibrated: the worker
    # always burns some CPU (twelve Resque workers polling Redis, resque-scheduler,
    # cron), measured at 91-211 ms per 3 s on an idle container.  Anything above
    # 900 ms/3 s is a leftover sampler or a real submission and is refused there.
    assert_worker_is_clean()
    records = []
    for rep in range(1, reps + 1):
        for parallel in levels:
            for arm in ("nopch", "pch"):
                compiles = compiles_for_level(parallel, target)
                cgroup_before = worker_cpu_usec()
                probe = compile_probe(parallel, compiles, arm, tag, ticks_per_s)
                cgroup_ms = (worker_cpu_usec() - cgroup_before) / 1000.0
                record = {
                    "sweep": "parallel",
                    "rep": rep,
                    "compiles": compiles,
                    **probe,
                    "wall_ms_per_compile": round(probe["wall_s"] * 1000.0 / compiles, 1),
                    "cpu_ms_per_compile": round(probe["cpu_ms_total"] / compiles, 1),
                    "cgroup_cpu_ms": round(cgroup_ms, 1),
                    "cgroup_cpu_ms_per_compile": round(cgroup_ms / compiles, 1),
                }
                record["suspect"] = parallel_suspects(record)
                records.append(record)
                print_row_parallel(record)
    return records


def parallel_suspects(record):
    reasons = []
    if record["failed_compiles"]:
        reasons.append(
            f"{record['failed_compiles']} of {record['compiles']} compiles exited nonzero, so this "
            "level's CPU is missing whatever they did not do"
        )
    cgroup_ms = record["cgroup_cpu_ms"]
    if cgroup_ms > 0 and abs(cgroup_ms - record["cpu_ms_total"]) / cgroup_ms > 0.25:
        reasons.append(
            f"the container's cgroup charges {cgroup_ms:.0f} ms for this level while the shell's own "
            f"children account for {record['cpu_ms_total']:.0f} ms: something else was running "
            "in the container, or the accounting is wrong"
        )
    return reasons


def print_row_parallel(record):
    print(
        f"  par  n={record['parallel']:3d} arm={record['arm']:5s} rep={record['rep']} "
        f"compiles={record['compiles']:4d} "
        f"wall={fmt(record['wall_s'], '{:6.2f}')}s "
        f"cpu/compile={fmt(record['cpu_ms_per_compile'], '{:6.1f}')}ms "
        f"wall/compile={fmt(record['wall_ms_per_compile'], '{:6.1f}')}ms "
        f"cgroup/compile={fmt(record['cgroup_cpu_ms_per_compile'], '{:6.1f}')}ms"
    )
    for reason in record["suspect"]:
        print(f"        suspect: {reason}")


def summarise_parallel(records):
    """Per level and arm, the median of the repetitions, plus the two comparisons
    the report is written from: CPU per compile against one-way parallelism (a
    curve that climbs is contention), and the precompiled header against no
    precompiled header at that width."""
    per_level = {}
    for record in records:
        per_level.setdefault(record["parallel"], {}).setdefault(record["arm"], []).append(
            record["cpu_ms_per_compile"]
        )
    summary = []
    for parallel in sorted(per_level):
        arms = {arm: round(statistics.median(values), 1) for arm, values in per_level[parallel].items()}
        row = {"parallel": parallel, "reps": max(len(v) for v in per_level[parallel].values()), **arms}
        if arms.get("pch") and summary and summary[0].get("pch"):
            row["pch_cpu_vs_serial"] = round(arms["pch"] / summary[0]["pch"], 2)
        if arms.get("pch") and arms.get("nopch"):
            row["pch_saving_x"] = round(arms["nopch"] / arms["pch"], 2)
        summary.append(row)
    return summary


def existing_tags(results_dir):
    """Every source tag an earlier run recorded. A tag reused in a `cold` sweep is
    not a cold sweep: the compilation cache still holds exactly those bytes, so
    the run would report the hit path as the compile. Any run, in this harness or
    in benchmark_pch.py, that wrote its tag into its results file is counted."""
    tags = set()
    for path in sorted(results_dir.glob("results_*.json")):
        try:
            payload = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(payload, dict):
            continue
        for key in ("tag", "nonce_base", "nonce"):
            value = payload.get(key)
            if isinstance(value, int):
                tags.add(value)
    return tags


def write_results(path, results):
    path.write_text(json.dumps(results, indent=2) + "\n")


def parse_number_list(text, option):
    try:
        return [int(part) for part in text.replace(" ", "").split(",") if part]
    except ValueError:
        raise SystemExit(f"{option} wants a comma separated list of integers, got {text!r}")


def print_summary(results):
    """What the report is written from: where each sweep peaked, how much the host
    drifted between the ladder's two passes at its opening concurrency, and the
    probe's scaling curve."""
    for sweep in ("cold", "hit"):
        records = [r for r in results["records"] if r["sweep"] == sweep and r["throughput_req_per_s"]]
        if not records:
            continue
        best = max(records, key=lambda record: record["throughput_req_per_s"])
        print(f"{sweep}: {best['throughput_req_per_s']} req/s at concurrency {best['concurrency']}")
        if len(records) > 1 and records[0]["concurrency"] == records[-1]["concurrency"]:
            print(
                f"{sweep}: the ladder opened and closed at concurrency {records[0]['concurrency']} at "
                f"{records[0]['throughput_req_per_s']} and {records[-1]['throughput_req_per_s']} req/s, "
                "so any host drift is in the difference between those two"
            )
    summary = results.get("parallel_summary") or []
    for row in summary:
        parts = [f"n={row['parallel']:3d}"]
        for arm in ("pch", "nopch"):
            if row.get(arm) is not None:
                parts.append(f"{arm}={row[arm]:6.1f}ms/compile")
        if row.get("pch_cpu_vs_serial") is not None:
            parts.append(f"vs serial={row['pch_cpu_vs_serial']:.2f}x")
        if row.get("pch_saving_x") is not None:
            parts.append(f"pch worth={row['pch_saving_x']:.2f}x")
        print("par  " + "  ".join(parts))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--label", required=True, help="names benchmarks/results_saturation_<label>.json")
    parser.add_argument(
        "--levels", default=",".join(str(c) for c in DEFAULT_LEVELS),
        help="concurrency ladder, in this order (the default opens and closes at the same value)",
    )
    parser.add_argument(
        "--total", type=int, default=None,
        help="requests per level; by default the small levels are given fewer, see requests_for_level",
    )
    parser.add_argument(
        "--sweeps", default="cold,hit,parallel",
        help="any of cold,hit,parallel. `hit` is the control for `cold` and needs it in the same run",
    )
    parser.add_argument(
        "--par-levels", default=",".join(str(c) for c in PARALLEL_LEVELS),
        help="parallel compile widths for the probe",
    )
    parser.add_argument(
        "--par-compiles", type=int, default=96,
        help="compiles per probe level, so every width does the same work",
    )
    parser.add_argument("--par-reps", type=int, default=2, help="repetitions of each probe level")
    parser.add_argument(
        "--nonce-base", type=int, default=None,
        help="source tag for this run; it has to be one no earlier run used, or `cold` is not cold",
    )
    args = parser.parse_args()

    levels = parse_number_list(args.levels, "--levels")
    par_levels = parse_number_list(args.par_levels, "--par-levels")
    sweeps = [part.strip() for part in args.sweeps.split(",") if part.strip()]
    unknown = [part for part in sweeps if part not in ("cold", "hit", "parallel")]
    if unknown:
        raise SystemExit(f"--sweeps does not know {', '.join(unknown)}: use cold, hit or parallel")
    if "hit" in sweeps and "cold" not in sweeps:
        raise SystemExit(
            "the hit sweep is the cold sweep's control: it sends back the sources cold just compiled. "
            "Run on its own, every one of its requests compiles and the control controls nothing.\n"
            "Use `--sweeps cold,hit` (which is the default)."
        )

    results_dir = ROOT / "benchmarks"
    results_path = results_dir / f"results_saturation_{args.label}.json"
    used = existing_tags(results_dir)
    if args.nonce_base is not None:
        if args.nonce_base in used:
            raise SystemExit(
                f"tag {args.nonce_base} is already in {results_dir}, so a cold sweep tagged with it "
                "would be measured against that run's compilation cache.\nPick another --nonce-base."
            )
        tag = args.nonce_base
    else:
        tag = random.randrange(10000, 1000000)
        while tag in used:
            tag = random.randrange(10000, 1000000)
    WORK_DIR.mkdir(parents=True, exist_ok=True)

    print(f"saturation sweep `{args.label}`, tag {tag}, sweeps {', '.join(sweeps)}")
    checks = preflight()
    print(
        f"preflight: {checks['gxx_version']} pch_engaged={checks['pch']['engaged']} "
        f"clock_ticks={checks['clock_ticks']} driver={checks['driver_ruby']} "
        f"sampler_cost={checks['sampler_cost']['cpu_ms']}ms over {checks['sampler_cost']['samples']} samples "
        f"idle_worker={checks['idle_worker_cpu_ms_over_3s']}ms/3s mac_load1={checks['host']['load1']}"
    )
    if "parallel" in sweeps and not checks["pch"]["engaged"]:
        raise SystemExit(
            "the probe's `pch` arm would be a copy of its `nopch` arm: "
            f"-I{PCH_DIR} is not making GCC read the precompiled header, so there is nothing to "
            "compare against.\nRebuild the worker image (`docker compose build worker && docker "
            f"compose up -d worker`) and check that `{GXX} -O0 -pipe t.cpp -I{PCH_DIR} -H -o t` "
            "inside it prints a .gch line."
        )

    results = {
        "label": args.label,
        "harness": "benchmarks/benchmark_saturation.py",
        "tag": tag,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "sweeps": sweeps,
        "levels": levels,
        "requests_per_level": args.total,
        "parallel_levels": par_levels if "parallel" in sweeps else [],
        "parallel_compiles_per_level": args.par_compiles,
        "parallel_reps": args.par_reps,
        "preflight": checks,
        "records": [],
        "parallel_records": [],
    }
    print(f"results will be written to {results_path} after every level")
    try:
        for sweep in [name for name in sweeps if name != "parallel"]:
            nonce = 0
            print(
                f"{sweep} sweep: {len(levels)} levels, "
                + ("the same request count at every level" if args.total else "requests scaled per level")
            )
            for concurrency in levels:
                total = args.total if args.total is not None else requests_for_level(concurrency)
                record, nonce = run_level(sweep, concurrency, total, tag, nonce, checks["driver_ruby"])
                results["records"].append(record)
                print_row(record)
                write_results(results_path, results)
        if "parallel" in sweeps:
            print(
                f"parallel compile probe: widths {' '.join(str(n) for n in par_levels)}, "
                f"{args.par_reps} reps, {args.par_compiles} compiles per level"
            )
            results["parallel_records"] = run_parallel_sweep(
                par_levels, args.par_reps, args.par_compiles, tag, checks["clock_ticks"]
            )
            results["parallel_summary"] = summarise_parallel(results["parallel_records"])
            write_results(results_path, results)
    finally:
        results["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        write_results(results_path, results)
        print(f"wrote {results_path}")
    print_summary(results)


if __name__ == "__main__":
    main()
