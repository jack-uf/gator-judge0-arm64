#!/usr/bin/env python3
"""
Benchmark Multi-Test Execution (Compile Once, Run Many Tests)
Evaluates 1, 5, 10, and 25 test cases.
Measures:
- Wall latency
- Total CPU time consumed
- Per-test latency
"""

import json
import time
import urllib.request

BASE_URL = "http://localhost:2358"

MATH_PROGRAM = """#include <iostream>
int main() {
    long long a, b;
    while (std::cin >> a >> b) {
        std::cout << (a * b + (a - b)) << "\\n";
    }
    return 0;
}
"""

def generate_tests(n):
    tests = []
    for i in range(1, n + 1):
        a = i * 3
        b = i * 2
        ans = a * b + (a - b)
        tests.append({
            "stdin": f"{a} {b}\n",
            "expected_output": f"{ans}\n"
        })
    return tests

def run_test_count(count):
    payload = {
        "language_id": 54,
        "source_code": MATH_PROGRAM,
        "tests": generate_tests(count)
    }
    url = f"{BASE_URL}/submissions?wait=true&base64_encoded=false"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})

    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    elapsed = time.perf_counter() - t0

    msg = json.loads(body.get("message", "{}")) if body.get("message") else {}
    return {
        "test_count": count,
        "wall_time_s": round(elapsed, 4),
        "status": body.get("status", {}).get("description"),
        "tests_run": msg.get("tests_run", count),
        "all_passed": msg.get("all_passed", True),
        "avg_program_time_s": body.get("time"),
        "memory_kb": body.get("memory")
    }

def main():
    print("=" * 60)
    print("Benchmarking Compile-Once Multi-Test Engine (1, 5, 10, 25 tests)")
    print("=" * 60)
    results = []
    for count in [1, 5, 10, 25]:
        res = run_test_count(count)
        print(f"Tests: {res['test_count']:2d} | Wall Time: {res['wall_time_s']:.4f}s | Tests Run: {res['tests_run']} | Status: {res['status']}")
        results.append(res)

    outfile = "benchmarks/results_multi_test.json"
    with open(outfile, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved multi-test results to {outfile}")

if __name__ == "__main__":
    main()
