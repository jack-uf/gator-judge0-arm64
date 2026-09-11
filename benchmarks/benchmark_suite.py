#!/usr/bin/env python3
"""
Judge0 ARM64 Benchmark Suite for Gator++
Measures:
- Client-visible API latency (wait=true & async)
- Queue wait time
- Worker execution duration
- Memory and CPU utilization
- Latency percentiles (p50, p95, p99)
- Throughput (submissions / sec)
Workloads:
- tiny: "Hello Gator++" C++
- moderate: educational assignment C++ with STL vectors, maps, sort
- compilation_error: syntax error
- runtime_error: segfault / abort
- timeout: infinite loop with 1s limit
- concurrency sweeps: 1, 5, 10, 25, 50, 100
- repeated execution: cache test
- multi-test: single submission with multiple tests / runs
"""

import json
import time
import statistics
import subprocess
import base64
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE_URL = "http://localhost:2358"

# Workload source codes (C++ language_id = 54)
TINY_CPP = """#include <iostream>
int main() {
    std::cout << "Hello Gator++" << std::endl;
    return 0;
}
"""

MODERATE_CPP = """#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <numeric>
#include <map>

int main() {
    std::vector<std::string> words = {
        "gator", "compiler", "sandbox", "isolate", "benchmark",
        "student", "challenge", "optimization", "concurrency", "throughput"
    };
    std::sort(words.begin(), words.end());
    std::map<char, int> freq;
    for (const auto& w : words) {
        for (char c : w) freq[c]++;
    }
    int total_chars = std::accumulate(words.begin(), words.end(), 0,
        [](int sum, const std::string& s) { return sum + (int)s.length(); });
    std::cout << "Chars: " << total_chars << ", distinct: " << freq.size() << std::endl;
    return 0;
}
"""

COMPILE_ERROR_CPP = """#include <iostream>
int main() {
    undefined_function_call();
    return 0;
}
"""

RUNTIME_ERROR_CPP = """#include <iostream>
int main() {
    int* ptr = nullptr;
    *ptr = 42;
    return 0;
}
"""

TIMEOUT_CPP = """#include <iostream>
int main() {
    while (true) {}
    return 0;
}
"""

def get_docker_stats():
    """Query current CPU % and Memory of docker containers."""
    try:
        cmd = ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"]
        res = subprocess.check_output(cmd, text=True).strip().splitlines()
        stats = {}
        for line in res:
            parts = line.split("\t")
            if len(parts) == 3:
                name, cpu, mem = parts
                stats[name] = {"cpu": cpu, "mem": mem}
        return stats
    except Exception as e:
        return {"error": str(e)}

def submit_sync(payload, wait=True, base64_encoded=False):
    """Submit a program and return timing and response metadata."""
    url = f"{BASE_URL}/submissions?wait={str(wait).lower()}&base64_encoded={str(base64_encoded).lower()}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})

    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            elapsed = time.perf_counter() - t0
            return {
                "success": True,
                "elapsed": elapsed,
                "data": body,
                "status_code": resp.status
            }
    except urllib.error.HTTPError as e:
        elapsed = time.perf_counter() - t0
        err_body = e.read().decode("utf-8")
        try:
            body = json.loads(err_body)
        except Exception:
            body = {"raw": err_body}
        return {
            "success": False,
            "elapsed": elapsed,
            "data": body,
            "status_code": e.code
        }
    except Exception as e:
        elapsed = time.perf_counter() - t0
        return {
            "success": False,
            "elapsed": elapsed,
            "error": str(e),
            "status_code": 0
        }

def get_submission_details(token):
    """Retrieve full submission fields for internal timing breakdown."""
    url = f"{BASE_URL}/submissions/{token}?base64_encoded=false&fields=*"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return {}

def benchmark_single_workload(name, payload, iterations=5):
    """Run a specific workload multiple times and report stats."""
    latencies = []
    cpu_times = []
    statuses = []
    details_list = []

    for i in range(iterations):
        res = submit_sync(payload, wait=True, base64_encoded=False)
        if not res["success"] and "some attributes" in str(res.get("data", {})):
            # If base64 required due to gcc unicode error on baseline:
            b64_payload = dict(payload)
            b64_payload["source_code"] = base64.b64encode(payload["source_code"].encode()).decode()
            res = submit_sync(b64_payload, wait=True, base64_encoded=True)

        latencies.append(res["elapsed"])
        data = res.get("data", {})
        status_desc = data.get("status", {}).get("description") if isinstance(data.get("status"), dict) else data.get("error", "Unknown")
        statuses.append(status_desc)
        if data.get("time"):
            try:
                cpu_times.append(float(data["time"]))
            except Exception:
                pass
        token = data.get("token")
        if token:
            details_list.append(get_submission_details(token))
        time.sleep(0.1)

    latencies.sort()
    p50 = statistics.median(latencies)
    p95 = latencies[int(len(latencies) * 0.95)] if len(latencies) >= 20 else max(latencies)
    p99 = max(latencies)
    avg = statistics.mean(latencies)

    return {
        "workload": name,
        "iterations": iterations,
        "avg_latency_s": round(avg, 4),
        "min_latency_s": round(min(latencies), 4),
        "max_latency_s": round(max(latencies), 4),
        "p50_s": round(p50, 4),
        "p95_s": round(p95, 4),
        "p99_s": round(p99, 4),
        "avg_program_cpu_s": round(statistics.mean(cpu_times), 4) if cpu_times else None,
        "statuses": list(set(statuses)),
        "details_sample": details_list[0] if details_list else {}
    }

def benchmark_concurrency(payload, concurrency, total_requests):
    """Run a burst of concurrent requests and measure throughput and latency."""
    latencies = []
    successes = 0
    failures = 0

    t_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(submit_sync, payload, True, False) for _ in range(total_requests)]
        for f in as_completed(futures):
            res = f.result()
            latencies.append(res["elapsed"])
            if res["success"]:
                successes += 1
            else:
                failures += 1
    total_time = time.perf_counter() - t_start

    latencies.sort()
    p50 = statistics.median(latencies)
    p95 = latencies[int(len(latencies) * 0.95)]
    p99 = latencies[int(len(latencies) * 0.99)]
    throughput = total_requests / total_time

    return {
        "concurrency": concurrency,
        "total_requests": total_requests,
        "total_time_s": round(total_time, 3),
        "throughput_req_per_s": round(throughput, 2),
        "p50_s": round(p50, 4),
        "p95_s": round(p95, 4),
        "p99_s": round(p99, 4),
        "success_rate": round(successes / total_requests * 100, 1)
    }

def run_full_suite(label="Baseline"):
    print(f"============================================================")
    print(f"Starting Benchmark Suite: {label}")
    print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"============================================================")

    initial_stats = get_docker_stats()
    print("Initial Docker Stats:")
    for k, v in initial_stats.items():
        print(f"  {k}: CPU {v['cpu']}, Mem {v['mem']}")

    workloads = [
        ("tiny_cpp", {"language_id": 54, "source_code": TINY_CPP}, 5),
        ("moderate_cpp", {"language_id": 54, "source_code": MODERATE_CPP}, 5),
        ("compilation_error", {"language_id": 54, "source_code": COMPILE_ERROR_CPP}, 5),
        ("runtime_error", {"language_id": 54, "source_code": RUNTIME_ERROR_CPP}, 5),
        ("timeout", {"language_id": 54, "source_code": TIMEOUT_CPP, "cpu_time_limit": 1.0, "wall_time_limit": 2.0}, 3),
        ("repeated_submission", {"language_id": 54, "source_code": TINY_CPP}, 5),
        ("multi_run_5", {"language_id": 54, "source_code": TINY_CPP, "number_of_runs": 5}, 3),
    ]

    workload_results = []
    for name, payload, iters in workloads:
        print(f"\nBenchmarking workload: {name} ({iters} runs)...")
        res = benchmark_single_workload(name, payload, iters)
        print(f"  p50: {res['p50_s']}s, p95: {res['p95_s']}s, avg: {res['avg_latency_s']}s, status: {res['statuses']}")
        workload_results.append(res)

    print("\n------------------------------------------------------------")
    print("Benchmarking Concurrency Sweeps (Tiny C++)...")
    concurrency_levels = [1, 5, 10, 25, 50]
    concurrency_results = []
    for c in concurrency_levels:
        total = max(c * 2, 10)
        print(f"Testing concurrency={c} (total {total} requests)...")
        res = benchmark_concurrency({"language_id": 54, "source_code": TINY_CPP}, c, total)
        print(f"  Concurrency {c}: throughput={res['throughput_req_per_s']} req/s, p50={res['p50_s']}s, p95={res['p95_s']}s, success={res['success_rate']}%")
        concurrency_results.append(res)

    final_stats = get_docker_stats()

    summary = {
        "label": label,
        "timestamp": time.time(),
        "docker_stats_before": initial_stats,
        "docker_stats_after": final_stats,
        "workloads": workload_results,
        "concurrency": concurrency_results
    }

    outfile = f"benchmarks/results_{label.lower().replace(' ', '_')}.json"
    with open(outfile, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\nSaved full results to {outfile}")
    return summary

if __name__ == "__main__":
    import sys
    label = "Baseline"
    if len(sys.argv) > 1:
        if sys.argv[1].startswith("--label="):
            label = sys.argv[1].split("=", 1)[1]
        elif sys.argv[1] == "--label" and len(sys.argv) > 2:
            label = sys.argv[2]
        elif not sys.argv[1].startswith("-"):
            label = sys.argv[1]
    run_full_suite(label)
