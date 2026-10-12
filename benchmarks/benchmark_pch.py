#!/usr/bin/env python3
"""
Precompiled-header benchmark: five C++ program shapes, measured twice.

The point of this harness is that every submission it sends is a *cold*
compile. The existing suite repeats one source code, so after the first
submission it measures the compilation cache, not the compiler; a PCH cannot
change a cache hit at all. Each program here carries a fixed-width trailing
comment, `// 0001`, so no two submissions hash the same and the compile cache
always misses. The comment is the same width in both passes, so the two passes
send byte-identical source sets.

Run it twice, once with the PCH installed and once without, and compare:

    python3 benchmarks/benchmark_pch.py --label pch_on
    # hide the manifest, restart the worker, then:
    python3 benchmarks/benchmark_pch.py --label pch_off

CPU per submission comes from the worker container's own cgroup
(`/sys/fs/cgroup/cpu.stat`, cgroup v2), read before and after each block, so it
counts the compiler, Isolate and the Ruby worker together -- which is the number
the VPS-sizing table wants. It is not the `time` field Judge0 reports, which
covers only the run phase.

Peak memory is sampled, not exact: this kernel does not let `memory.peak` be
reset, so each shape is measured by reading `memory.current` in a tight loop
inside the container while the shape's compiles run, and the maximum is
reported. Sampling resolution is about a millisecond.
"""

import argparse
import json
import os
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

BASE_URL = "http://localhost:2358"
CONTAINER = "gator-judge0-arm64-worker-1"
CPP = 54
ROOT = Path(__file__).resolve().parent.parent

# The five shapes. `minimal_iostream` and `gator_student` are what the PCH is
# for; `no_include` is the control that cannot benefit, and is here so the
# report can say what the PCH costs a program that never touches <iostream>.
#
# `expects_pch` says whether this shape includes anything the PCH covers. It is
# an assertion, not a hint: a shape that includes headers while reporting that
# it read the plain header means the PCH silently did not engage, and every
# timing from that run is meaningless.
SHAPES = [
    (
        "minimal_iostream",
        {
            "expects_pch": True,
            "source_code": """#include <iostream>
int main() {
    std::cout << "Hello Gator++" << std::endl;
    return 0;
}
""",
            "stdin": "",
        },
    ),
    (
        "gator_student",
        {
            "expects_pch": True,
            "source_code": """#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <iomanip>

int main() {
    int n;
    std::cin >> n;
    std::vector<int> values(n);
    for (int i = 0; i < n; i++) std::cin >> values[i];
    std::sort(values.begin(), values.end());
    double total = 0;
    for (int v : values) total += v;
    std::cout << std::fixed << std::setprecision(2) << total / n << "\\n";
    for (int v : values) std::cout << v << " ";
    std::cout << "\\n";
    return 0;
}
""",
            "stdin": "5\n3 1 4 1 5\n",
        },
    ),
    (
        "template_heavy",
        {
            "expects_pch": True,
            "source_code": """#include <iostream>
#include <map>
#include <vector>
#include <string>
#include <memory>
#include <functional>
#include <algorithm>

template <typename T>
struct Accumulator {
    T total{};
    void add(const T& value) { total += value; }
    template <typename F> T map_reduce(F f) const { return f(total); }
};

template <typename K, typename V>
std::vector<K> keys_of(const std::map<K, V>& m) {
    std::vector<K> keys;
    for (const auto& pair : m) keys.push_back(pair.first);
    return keys;
}

int main() {
    auto acc = std::make_unique<Accumulator<long>>();
    std::map<std::string, std::vector<int>> buckets;
    for (int i = 0; i < 100; i++) buckets["k" + std::to_string(i % 7)].push_back(i);
    for (const auto& pair : buckets)
        for (int v : pair.second) acc->add(v);
    std::function<long(long)> twice = [](long x) { return x * 2; };
    auto keys = keys_of(buckets);
    std::sort(keys.begin(), keys.end(), [](const std::string& a, const std::string& b) {
        return a.size() != b.size() ? a.size() < b.size() : a < b;
    });
    std::cout << acc->map_reduce(twice) << " " << keys.front() << "\\n";
    return 0;
}
""",
            "stdin": "",
        },
    ),
    (
        "several_headers",
        {
            "expects_pch": True,
            "source_code": """#include <iostream>
#include <sstream>
#include <vector>
#include <map>
#include <set>
#include <string>
#include <algorithm>
#include <numeric>
#include <cmath>
#include <iomanip>
#include <cstdio>
#include <cstdlib>

int main() {
    std::set<std::string> seen;
    std::istringstream in("alpha beta gamma alpha");
    std::string word;
    while (in >> word) seen.insert(word);
    std::vector<int> values(10);
    std::iota(values.begin(), values.end(), 1);
    int sum = std::accumulate(values.begin(), values.end(), 0);
    std::printf("%.3f %zu %d\\n", std::sqrt(sum), seen.size(), std::abs(-sum));
    return 0;
}
""",
            "stdin": "",
        },
    ),
    (
        "no_include",
        {
            # No headers at all, so there is nothing for a precompiled header to
            # replace. This case measures what the PCH costs a submission that
            # cannot benefit from it, and doubles as the control: its ratio is
            # the host's noise floor.
            "expects_pch": False,
            "source_code": """int main() {
    int total = 0;
    for (int i = 0; i < 1000; i++) total += i;
    return total * 0;
}
""",
            "stdin": "",
        },
    ),
]


def docker_exec(script, timeout=60):
    out = subprocess.run(
        ["docker", "exec", "-u", "root", CONTAINER, "sh", "-c", script],
        capture_output=True, text=True, timeout=timeout,
    )
    if out.returncode != 0:
        raise RuntimeError(f"docker exec failed: {out.stderr.strip()}")
    return out.stdout.strip()


def worker_cpu_usec():
    """Total CPU the worker container has burned, in microseconds."""
    text = docker_exec("grep '^usage_usec' /sys/fs/cgroup/cpu.stat")
    return int(text.split()[1])


def worker_memory_current():
    return int(docker_exec("cat /sys/fs/cgroup/memory.current"))


def worker_cpu_split():
    text = docker_exec("grep -E '^(user|system)_usec' /sys/fs/cgroup/cpu.stat | cut -d' ' -f2 | tr '\\n' ' '")
    user, system = (int(x) for x in text.split()[:2])
    return user, system


def assert_worker_is_clean():
    """Refuse to measure a container that is already busy.

    A leftover sampler loop from an interrupted run burns several cores, and
    because CPU per submission is a *difference* of two cgroup readings it does
    not show up as an obvious outlier -- it showed up as ten times the plausible
    number. Nothing here is worth reporting unless the container starts idle.
    """
    strays = docker_exec(
        'me=$$; n=0; for p in /proc/[0-9]*; do pid=${p#/proc/}; [ "$pid" = "$me" ] && continue; '
        'cmd=$(tr "\\0" " " < $p/cmdline 2>/dev/null); '
        'case "$cmd" in *pch_mem_peak*) n=$((n+1));; esac; done; echo $n'
    )
    if int(strays) > 0:
        raise SystemExit(f"{strays} sampler loop(s) still running in {CONTAINER}; kill them first")

    before = worker_cpu_usec()
    time.sleep(3)
    burned_ms = (worker_cpu_usec() - before) / 1000.0
    if burned_ms > 900:
        raise SystemExit(
            f"{CONTAINER} burned {burned_ms:.0f} ms of CPU while idle; "
            "something else is running and the CPU numbers would be meaningless"
        )
    return burned_ms


def source_with_nonce(source, index):
    """Same length for the same index in every pass, different for every index."""
    return f"{source}// {index:04d}\n"


def submit(payload, timeout=60):
    url = f"{BASE_URL}/submissions?wait=true&base64_encoded=false"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            return time.perf_counter() - started, body, resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            body = json.loads(raw)
        except Exception:
            body = {"raw": raw}
        return time.perf_counter() - started, body, exc.code


def percentile(sorted_values, fraction):
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    return sorted_values[min(len(sorted_values) - 1, int(round(fraction * (len(sorted_values) - 1))))]


def summarise(latencies, cpu_usec, user_usec, system_usec, responses, peak_memory):
    ordered = sorted(latencies)
    cpu_per = cpu_usec / len(latencies) / 1000.0 if latencies else None
    return {
        "submissions": len(latencies),
        "wall_ms_p50": round(percentile(ordered, 0.50) * 1000, 1),
        "wall_ms_p95": round(percentile(ordered, 0.95) * 1000, 1),
        "wall_ms_p99": round(percentile(ordered, 0.99) * 1000, 1),
        "wall_ms_mean": round(statistics.mean(latencies) * 1000, 1) if latencies else None,
        "wall_ms_min": round(ordered[0] * 1000, 1) if ordered else None,
        "wall_ms_max": round(ordered[-1] * 1000, 1) if ordered else None,
        "cpu_ms_per_submission": round(cpu_per, 1) if cpu_per else None,
        "user_ms_per_submission": round(user_usec / len(latencies) / 1000.0, 1) if (latencies and user_usec) else None,
        "system_ms_per_submission": round(system_usec / len(latencies) / 1000.0, 1) if (latencies and system_usec) else None,
        "run_phase_cpu_s_mean": round(statistics.mean(
            [float(r["time"]) for r in responses if r.get("time")]), 4
        ) if any(r.get("time") for r in responses) else None,
        "run_phase_memory_kb_mean": round(statistics.mean(
            [r["memory"] for r in responses if r.get("memory")]), 1
        ) if any(r.get("memory") for r in responses) else None,
        "peak_container_memory_mib": round(peak_memory / 1024 / 1024, 1) if peak_memory else None,
        "statuses": sorted({(r.get("status") or {}).get("description", "?") for r in responses}),
        "compile_output_present": sum(1 for r in responses if r.get("compile_output")),
    }


def run_shape(name, shape, iterations, nonce_base, warmup=2):
    """One block of cold compiles, CPU measured across the whole block."""
    responses = []
    latencies = []

    # The first submissions into a freshly restarted worker pay for the worker's
    # own warm-up (Rails boot, Isolate box creation, page cache) -- measured at
    # around 3 s on the first one, which would otherwise dominate a 15-sample
    # block. They are sent, and thrown away, before the CPU window opens.
    for i in range(warmup):
        submit({
            "language_id": CPP,
            "source_code": source_with_nonce(shape["source_code"], 9000 + i),
            "stdin": shape["stdin"],
        })

    cpu_before = worker_cpu_usec()
    user_before, system_before = worker_cpu_split()

    for i in range(iterations):
        payload = {
            "language_id": CPP,
            "source_code": source_with_nonce(shape["source_code"], nonce_base + i),
            "stdin": shape["stdin"],
        }
        elapsed, body, _status = submit(payload)
        latencies.append(elapsed)
        responses.append(body)

    cpu_after = worker_cpu_usec()
    user_after, system_after = worker_cpu_split()

    summary = summarise(
        latencies,
        cpu_after - cpu_before,
        user_after - user_before,
        system_after - system_before,
        responses,
        None,
    )

    # The last source of the block again, unchanged. If the compilation cache is
    # working this is a hit and should be far below the p50 above; the gap is
    # what shows the block really was compiling rather than replaying.
    hit_elapsed, _hit_body, _ = submit({
        "language_id": CPP,
        "source_code": source_with_nonce(shape["source_code"], nonce_base + iterations - 1),
        "stdin": shape["stdin"],
    })
    summary["same_source_again_ms"] = round(hit_elapsed * 1000, 1)
    return summary


def run_memory_pass(name, shape, iterations, nonce_base):
    """Peak container memory while the same compiles run, sampled inside the box."""
    for i in range(2):
        submit({
            "language_id": CPP,
            "source_code": source_with_nonce(shape["source_code"], 9000 + i),
            "stdin": shape["stdin"],
        })
    # The sampler is stopped through the filesystem, not by killing the local
    # `docker exec` client: killing the client leaves the shell loop inside the
    # container running, and a busy loop there inflates the CPU numbers of every
    # later measurement. The time bound is the safety net for a harness that dies.
    stamp = f"{os.getpid()}-{abs(hash(name)) % 10000}"
    peak_file = f"/tmp/pch_mem_peak.{stamp}"
    stop_file = f"/tmp/pch_mem_peak.{stamp}.stop"
    docker_exec(f"rm -f {peak_file} {stop_file}")
    sampler = subprocess.Popen(
        ["docker", "exec", "-u", "root", CONTAINER, "sh", "-c",
         'max=0; end=$(( $(date +%s) + 300 )); '
         f'while [ ! -f {stop_file} ] && [ "$(date +%s)" -lt "$end" ]; do '
         'read -r v < /sys/fs/cgroup/memory.current; '
         f'if [ "$v" -gt "$max" ]; then max=$v; printf "%s\\n" "$max" > {peak_file}; fi; '
         'sleep 0.01; done'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(0.5)
        for i in range(iterations):
            submit({
                "language_id": CPP,
                "source_code": source_with_nonce(shape["source_code"], nonce_base + i),
                "stdin": shape["stdin"],
            })
    finally:
        docker_exec(f"touch {stop_file}")
        sampler.wait(timeout=30)
    peak = int(docker_exec(f"cat {peak_file} 2>/dev/null || echo 0").strip() or 0)
    docker_exec(f"rm -f {peak_file} {stop_file}")
    return peak


def run_concurrency(concurrency, total, nonce_base):
    """Cold compile throughput: every request is a distinct source."""
    shape = SHAPES[1][1]  # the representative student program
    payloads = [
        {
            "language_id": CPP,
            "source_code": source_with_nonce(shape["source_code"], nonce_base + i),
            "stdin": shape["stdin"],
        }
        for i in range(total)
    ]

    cpu_before = worker_cpu_usec()
    started = time.perf_counter()
    results = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(submit, p) for p in payloads]
        for future in as_completed(futures):
            results.append(future.result())
    wall = time.perf_counter() - started
    cpu_after = worker_cpu_usec()

    latencies = [r[0] for r in results]
    responses = [r[1] for r in results]
    summary = summarise(latencies, cpu_after - cpu_before, None, None, responses, None)
    summary.update({
        "concurrency": concurrency,
        "total_requests": total,
        "wall_s": round(wall, 3),
        "throughput_req_per_s": round(total / wall, 2),
        "cold_compiles": True,
    })
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument(
        "--nonce-base", type=int, default=None,
        help="first comment number to stamp on the sources. Every run defaults "
             "to a fresh range, because reusing numbers means reusing cache keys "
             "and measuring the compilation cache instead of the compiler.",
    )
    parser.add_argument("--iterations", type=int, default=15)
    parser.add_argument("--memory-iterations", type=int, default=5)
    parser.add_argument("--concurrency", type=int, default=25)
    parser.add_argument("--concurrency-total", type=int, default=200)
    parser.add_argument("--skip-memory", action="store_true")
    parser.add_argument("--skip-concurrency", action="store_true")
    args = parser.parse_args()

    nonce_base = args.nonce_base if args.nonce_base is not None else int(time.time()) % 1_000_000 * 100
    report = {
        "label": args.label,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "iterations_per_shape": args.iterations,
        "nonce_base": nonce_base,
        "cold_compiles": True,
        "worker_container": CONTAINER,
        "shapes": {},
        "throughput": None,
    }

    manifest = docker_exec("ls /usr/local/pch/c++/pch.sha256 2>/dev/null || true")
    report["pch_manifest_installed"] = bool(manifest)
    report["pch_include_arg_offered"] = bool(manifest)
    report["idle_cpu_ms_over_3s"] = round(assert_worker_is_clean(), 1)

    idle_memory = worker_memory_current()
    report["idle_container_memory_mib"] = round(idle_memory / 1024 / 1024, 1)
    print(f"label={args.label} manifest_installed={report['pch_manifest_installed']} "
          f"idle={report['idle_container_memory_mib']} MiB")

    nonce = nonce_base
    for name, shape in SHAPES:
        result = run_shape(name, shape, args.iterations, nonce)
        nonce += args.iterations
        report["shapes"][name] = result
        print(f"  {name:18s} p50={result['wall_ms_p50']:8.1f}ms "
              f"p95={result['wall_ms_p95']:8.1f}ms cpu/sub={result['cpu_ms_per_submission']:7.1f}ms "
              f"status={result['statuses']} compile_output={result['compile_output_present']}")

    if not args.skip_memory:
        for name, shape in SHAPES:
            peak = run_memory_pass(name, shape, args.memory_iterations, nonce)
            nonce += args.memory_iterations
            report["shapes"][name]["peak_container_memory_mib"] = round(peak / 1024 / 1024, 1)
            print(f"  {name:18s} peak container memory={round(peak / 1024 / 1024, 1)} MiB")

    if not args.skip_concurrency:
        report["throughput"] = run_concurrency(args.concurrency, args.concurrency_total, nonce)
        print(f"  cold throughput c={args.concurrency}: "
              f"{report['throughput']['throughput_req_per_s']} req/s "
              f"p50={report['throughput']['wall_ms_p50']}ms "
              f"cpu/sub={report['throughput']['cpu_ms_per_submission']}ms")

    report["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    out = ROOT / "benchmarks" / f"results_pch_{args.label}.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
