# Judge0 ARM64 / Gator++ Optimization Report

This report documents what was slow in the ARM64 Judge0 fork that powers
Gator++, what was changed, and what the measured results were. It is written to
be readable by someone who did not sit through the development process.

Every number below is measured on this machine by the checked-in benchmark
suite. Nothing is extrapolated, and no percentage improvements are combined --
the final section reports one measurement of the final system.

---

## 1. How to reproduce

```sh
cd native_judge0
docker compose up -d --build          # rebuild so the image matches HEAD
python3 benchmarks/benchmark_suite.py --label <label>
```

Results land in `benchmarks/results_<label>.json`. The correctness checks are
standalone and need no gems:

```sh
ruby checks/check_exec_plan.rb          # 142 language command definitions swept
ruby checks/check_compilation_cache.rb
ruby checks/check_sandbox_argv.rb
ruby checks/check_base64_service.rb
ruby checks/check_wait_budget.rb
sh   checks/check_isolate_wrapper.sh
ruby checks/check_language_seed.rb      # 11 languages seeded, and they match the image
ruby checks/check_pch.rb                # the precompiled-header gate, against real files
python3 checks/check_saturation_sampler.py  # the sampler reads the queue that exists
python3 checks/check_pool_structure.py      # section 17's pool readings, re-derived
docker exec -i -u root native_judge0-worker-1 sh -s < checks/check_pch.sh
                                        # ...and the same gate through a real Isolate compile
```

All eleven pass on the current HEAD. The two Python checks need no containers:
the sampler check puts a stub `redis-cli` on PATH, and the pool check reads the
committed ladder record. `check_pch.sh` runs inside the worker container -- it
needs the image's own header and `isolate` -- and takes the first free box out
of 990-999, so it fails with `no free Isolate box` if a submission is running
at the same moment.

## 2. System under test

| Component | Value |
| --- | --- |
| Host | Apple Silicon (ARM64), Docker Desktop |
| Docker VM memory | 7.652 GiB |
| Judge0 API | `http://localhost:2358`, docker-compose maps `2358:2358` |
| Language under test | id 54, seeded as `C++ (GCC 9.2.0)`, `source_file: main.cpp`. The language *name* is inherited from the seed and the compiler is not: `/usr/local/gcc-9.2.0/bin/g++` is a symlink to `/usr/bin/g++`, which is **g++ 11.4.0** for `aarch64-linux-gnu`. Every timing in this report is 11.4.0. |
| Server mode | `wait=true` (synchronous) -- the worst case, not the typical path |
| Worker pool | `COUNT` (= `nproc`) Resque workers, `FORK_PER_JOB=false` |
| Worker image | `judge0:arm64-native`. Since section 14 it is C++-only (806 MB on disk) and serves 11 language ids; the runs in sections 6-8 were taken on the image before that change. |

The benchmark's concurrency sweep reuses a single `TINY_CPP` source for every
request. Those throughput numbers are therefore **compilation-cache-hit**
throughput -- re-submitting the same program, which is Gator++'s common case.
They are not compile throughput.

## 3. Bottlenecks found

1. **A fixed ~30 s stall on a fraction of submissions.** In the baseline,
   `timeout` (a workload whose own limits are `cpu_time_limit: 1.0`,
   `wall_time_limit: 2.0`) had a p50 of **30.0056 s**, and almost every other
   workload showed a p95 of ~30.00 s. The consistency of those values points at
   a fixed timeout in the completion path, not at load.
2. **The worker polled for completion** instead of being told. Two shell
   invocations per submission (`compile`, `run`) plus a poll loop.
3. **Every submission recompiled.** No compilation cache existed, so a repeated
   submission paid a full `g++` compile.
4. **The toolchain fingerprint was blind.** `CompilationCache.toolchain_fingerprint`
   used `compile_cmd.to_s.split(" ").first`, which for any language definition
   with a leading `VAR=value` (GOCACHE for Go, `LD_LIBRARY_PATH` for GCC, `PATH`
   for Prolog) stat'd the *assignment*, not the compiler. Every entry for those
   languages collapsed onto one constant `unknown:VAR=...` key.
5. **Distinct bytes compared equal, so wrong answers could be graded Accepted.**
   `Base64Service.clean_utf8` replaced every non-UTF-8 byte with `?`. The verdict
   compares `Submission#expected_output` against a raw read of the sandbox
   stdout, so printing `0xFE` and printing `0xFF` compared equal. Reproduced
   under Ruby 2.6.10: `expected bytes=[63] actual bytes=[63]`,
   `distinct bytes decode EQUAL: true`. This was the most serious defect found.
6. **Arguments were re-split from strings.** The lifecycle calls interpolated
   argv into a command string, so `extract_archive` produced `-m 512000` as a
   single token -- the flag `-m` with an empty variable name.

## 4. What was fixed

Eight commits on `judge0-src` `master`, from the upstream base `9eba69f`:

| Commit | Change |
| --- | --- |
| `c32bf4d` | Deliver `additional_files` to the sandbox again, and keep binary blobs binary |
| `70c0fe6` | Exec submissions by argv instead of through two shells; stop polling for completion |
| `26284fa` | Cache compile failures alongside successful binaries |
| `02e38c7` | Run the sandbox lifecycle by argv too; stop re-splitting arguments |
| `13e9e80` | Collapse the queued-state write into the `INSERT` |
| `481510b` | Fingerprint the toolchain through the argv parser (fixes finding 4) |
| `46b57fc` | Decode stored text as bytes instead of replacing invalid sequences (fixes finding 5) |
| `28ce721` | Seed only the languages the ARM64 image can actually run (section 14) |

Scope: 13 files, +1021 / -178 lines.

```
app/controllers/submissions_controller.rb   app/services/base64_service.rb
app/helpers/isolate_runner.rb               app/services/compilation_cache.rb
app/jobs/isolate_job.rb                     app/services/exec_plan.rb
app/models/submission.rb                    app/services/judge0_redis.rb
app/services/sandbox_command.rb             app/services/submission_show_payload.rb
config/initializers/resque.rb               db/seeds.rb
scripts/load-config
```

Honest scoping note on `02e38c7`: the mis-split `-m 512000` token was in the
rlimit branch, which is selected by `enable_per_process_and_thread_memory_limit`.
`judge0.conf` does not select it (the benchmark confirms both
`enable_per_process_and_thread_*` flags are `false`), so that specific bug was
latent. The real gain there is one fewer shell per lifecycle call, plus correct
parsing if the flag is ever flipped.

## 5. Architecture: before and after

Before (per submission): the request enqueued a job, then **polled** the
submission row for completion; completion ran `isolate ... compile` and
`isolate ... run` as **two shell command strings** built by interpolation; every
submission recompiled.

After:

- `ExecPlan.parse` turns each language's `compile_cmd` / `run_cmd` into an argv
  vector once, and everything downstream consumes argv. No shell is involved in
  the submission path.
- The worker is notified of completion (`Judge0Redis`) instead of polling.
- Resque reserves via blocking `BLPOP` (`ResqueBlockingWorker`, prepended in
  `config/initializers/resque.rb`), `FORK_PER_JOB=false`.
- `CompilationCache` stores the compiled binary -- and, since `26284fa`, the
  failure -- under a content-addressed key.
- `SandboxCommand` / `SubmissionShowPayload` keep argv construction and response
  shaping in one place each.
- The worker image carries only the toolchains a seeded language points at, and
  the seed creates only those languages (section 14). The API service no longer
  runs privileged; the worker keeps the grant Isolate needs.

`app/jobs/isolate_job.rb` now contains **zero backtick shell execution**.

## 6. Baseline results

`benchmarks/results_baseline.json` -- the pre-optimization state. p95 and p99
are the maximum observed value, because `n=5` for most workloads: at that sample
size the 95th percentile *is* the largest sample, so treat the baseline's
`30.00xx` entries as "the worst of five", not as a fitted tail.

## 7. Per-optimization results

`tiny_cpp`, `n=5`, `wait=true`. The `submissions/sec` column is throughput at
`concurrency=10` for every stage so the column is comparable across rows.
`RSS` was only sampled for the baseline and the final combined state.
`CPU/submission` is the *program's* own CPU time (`Submission#time`), not
whole-system CPU; the baseline file does not record it.

| Version | p50 | p95 | p99 | CPU/submission | submissions/sec | RSS |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline | 2.0549 | 30.0698 | n/a (n=5) | — | 4.74 | 1.76 GiB (under load) |
| Event_Completion | 0.6146 | 0.8084 | 0.8084 | 0.0018 | 8.68 | — |
| Blocking_Queue_NoFork | 0.2505 | 0.5681 | 0.5681 | 0.0012 | 20.71 | — |
| Tmpfs_No_Sudo | 0.5364 | 0.8488 | 0.8488 | 0.0024 | 29.37 | — |
| compilation_cache | 0.0299 | 0.6640 | 0.6640 | 0.0016 | 22.45 | — |
| **combined_current** (all 7 commits, cold) | **0.3205** | **0.9583** | **0.9583** | 0.0018 | 24.90 | 1.00 GiB |

The `compilation_cache` row looks better than the combined row because its
compilation cache was already warm when it ran. See section 9.

## 8. Final combined results

`benchmarks/results_combined_current.json`, taken at HEAD (`46b57fc`), image
built 00:37:52, run started 00:40:23. The image contains all seven commits that
existed at that point: the last commit predates the build by seven minutes, the
working tree is clean, and no file under `app/`, `config/`, or `db/` was
modified after the build.

Two changes landed after this run: the C++-only worker image and the language
seed filter (`28ce721`), both documented in section 14. They were measured in
their own run, `benchmarks/results_cpp_only.json`, and section 14 prints those
numbers. Nothing in this section has been re-derived from them, and no ratio
below mixes the two runs.

### Latency by workload (seconds)

| Workload | Baseline p50 | Combined p50 | Baseline p95 | Combined p95 |
| --- | --- | --- | --- | --- |
| tiny_cpp | 2.0549 | 0.3205 | 30.0698 | 0.9583 |
| moderate_cpp | 2.0447 | 0.0264 | 30.0084 | 0.4217 |
| compilation_error | 2.0463 | 0.0253 | 2.2446 | 0.3416 |
| runtime_error | 2.0380 | 0.3410 | 30.0024 | 0.4631 |
| timeout | 30.0056 | 1.1292 | 30.0081 | 1.3300 |
| repeated_submission | 2.1453 | 0.0264 | 30.0023 | 0.0370 |
| multi_run_5 | 2.0402 | 0.0336 | 2.0713 | 0.0443 |

The `timeout` row is the clearest product-facing win: a submission with a 1 s
CPU limit and a 2 s wall limit went from a 30 s p50 to 1.13 s p50.

### Throughput (warm cache, identical source -- read section 9 caveat 3 first)

| Concurrency | Baseline req/s | Combined req/s |
| --- | --- | --- |
| 1 | 0.50 | 47.80 |
| 5 | 0.30 | 102.52 |
| 10 | 4.74 | 24.90 |
| 25 | 6.05 | 82.29 |
| 50 | 6.10 | 121.75 |

Baseline rows are from the recorded concurrency sweep; combined rows are from
this run. Success rate was 100% at every level in both. Both columns are
undersampled and the two runs did not use the same request count per level, so
do not read a ratio across a row of this table.

### Headline improvements

These are four separate measured ratios of two measured values. They are not
summed or compounded, and they do not describe the same request:

| Measure | Baseline | Combined | Ratio |
| --- | --- | --- | --- |
| `tiny_cpp` p50, cold (first run after deploy) | 2.0549 | 0.3205 | 6.4x |
| `tiny_cpp` p95 | 30.0698 | 0.9583 | 31.4x |
| `timeout` p50 (1 s CPU / 2 s wall limit) | 30.0056 | 1.1292 | 26.6x |
| `repeated_submission` p50 (warm cache) | 2.1453 | 0.0264 | 81.3x |

The throughput ratio that used to sit in that table has been removed. The
concurrency sweep behind it was undersampled -- see section 9 caveat 3 -- so
`82.29 req/s` was not a supportable number, and the baseline's old sweep is not
comparable to it level for level either. The corrected throughput measurement
for the current state stands on its own in section 9 caveat 3: 76.59 req/s at
concurrency 25 with 200 requests, degrading past that knee. That curve is a
cache-hit curve -- section 17 is where the mechanism behind it, and the
12-worker pool structure underneath it, are attributed.

## 9. Three caveats you should not read past

**The combined run started with a cold compilation cache.** Containers came up
about 15 seconds before the first submission, so `tiny_cpp` -- the first
workload -- paid real compiles. Its five samples averaged 0.3581 s with a
minimum of 0.0661 s and a maximum of 0.9583 s: the spread of a cold first
iteration followed by cache hits. The evidence that the cache then worked is the
next workload: `moderate_cpp` uses a *different* source, and its p50 is 0.0264 s
with a 0.4217 s maximum -- one compile, then hits. `repeated_submission` (the
same source as `tiny_cpp`) also lands at 0.0264 s.

So the honest reading is: **cold ≈ 0.32-0.96 s, warm ≈ 0.025-0.034 s.** The
standalone `compilation_cache` run measured 0.0299 s warm, which agrees.
Do not quote 0.0299 s as the headline cold-start figure.

**`runtime_error` has the same shape, and an earlier draft of this report
misread it as a defect.** The `runtime_error` source is compiled for the first
time inside its own five-iteration workload, so its p50 carries a cold compile
exactly like `tiny_cpp`. Measured directly against the live stack, one source
per submission, each submitted once and then repeated:

| Source | run 1 | run 2 | run 3 | Status |
| --- | --- | --- | --- | --- |
| clean program, not seen before | 484.8 ms | 54.2 ms | 43.5 ms | Accepted |
| `SIGSEGV` program, not seen before | 100.5 ms | 55.0 ms | 37.9 ms | Runtime Error (SIGSEGV) |
| warm `hello`, seen before | 35.4 ms | 36.9 ms | -- | Accepted |

A crashing program is not penalized: its run 2 and run 3 match a clean
program's. The `0.3410 s` in the `runtime_error` row is a cold compile that
then crashed, not a 340 ms crash path, and the `submission.time` of 0.0 s on
those runs confirms the cached-binary path works for failures too. There is no
crash-path defect to fix.

One detail is worth recording because it cost real time to find. The
compilation cache is `tmp/cache/binaries` -- `CompilationCache::CACHE_DIR`,
which defaults to `Rails.root.join("tmp", "cache", "binaries")`. The
three-character hex directories sitting directly under `tmp/cache/` (`0B1`,
`120`, `1C3`, ...) are Rails' `FileStore` sharding for the show-payload cache,
not compilation entries. Counting that directory produces confident and wrong
statements about whether the compilation cache was cold.

**The shipped concurrency sweep is undersampled, and its curve is wrong.** The
first version of the throughput table read 47.8, 102.5, 24.9, 82.3, 121.8 req/s
and looked non-monotonic at concurrency 10. The harness asks for
`max(c * 2, 10)` requests per level, so c=10 was 20 requests, one of which took
~0.8 s -- and that single request set both the wall time and the p95. Re-running
the same code path with 200 requests per level gives a monotonic curve:

| Concurrency | Requests | Throughput req/s | p50 s | p95 s |
| --- | --- | --- | --- | --- |
| 5 | 200 | 43.20 | 0.0741 | 0.2806 |
| 10 | 200 | 66.31 | 0.1445 | 0.2312 |
| 25 | 200 | 76.59 | 0.3096 | 0.4356 |
| 50 | 200 | 57.48 | 0.7322 | 1.1719 |

Two 400-request confirmation runs put concurrency 25 at 66.97 and 68.82 req/s
and concurrency 50 at 60.00 and 59.11 req/s. So the curve rises to a knee near
concurrency 25 and then degrades: by concurrency 50 the p50 has more than
doubled while throughput falls. That is the shape to size a deployment against,
and it replaces the earlier "unresolved, do not guess" note. Section 17 carries
the attribution as far as this fork's structure allows: a 12-worker pool behind
24 API slots, with Postgres, Redis, memory, the cgroup CPU limit and context
switches all flat at the moment the cold curve knees. This cache-hit curve is
not bound by that pool -- section 17's control sweep takes the same pool to
84.57 req/s at concurrency 100, limited there by the client driver rather than
by the system. What section 17 leaves open is the absolute size of the cold,
compile-bearing execution window: host descheduling versus blocking in the
compile pathway, separable only by per-stage counters inside the worker.

Read the throughput row of every stage table in this report with that in mind:
at 10-100 requests per level, the shipped sweep cannot support a throughput
claim. The latency tables are unaffected -- those are per-request timings, not
throughput estimates -- and they were taken with the cache state described
above.

Also note that p95 and p99 equal the maximum at every stage because `n=5` (and
`n=3` for `timeout` and `multi_run_5`). The tails here are observations, not
estimates. Any claim about real p99 needs a longer run.

## 10. Memory impact

`docker stats`, sampled at the start and end of the combined run:

| Container | Before | After |
| --- | --- | --- |
| worker | 825.4 MiB | 1023 MiB |
| server | 102.1 MiB | 225.9 MiB |
| db | 26.93 MiB | 112.9 MiB |
| redis | 12.73 MiB | 12.92 MiB |

Peak observed total is about **1.38 GiB**. The worker's growth (825 MiB to
1.02 GiB) is the Ruby worker pool plus the compilation cache; the server and db
growth is Rails and Postgres warming up after a fresh start.

The baseline's recorded worker figure was 1.76 GiB at 70.39% CPU -- sampled
while it was still busy, so it is not a like-for-like idle comparison. I would
not claim a memory reduction from these two numbers; the defensible statement is
that the current state peaks near 1.4 GiB under this load.

Those figures are run-start and run-end samples of a busy stack. The stack was
also sampled while idle -- no submissions in flight, several minutes after the
C++-only image came up:

| Container | Idle RSS |
| --- | --- |
| worker | 866-889 MiB |
| server | 126-140 MiB |
| db | 33.1 MiB |
| redis | 10.1-10.3 MiB |

Three consecutive readings of the worker gave 866.1, 866.9 and 869.4 MiB, and
earlier idle samples in the same state reached 889 MiB; the server gave 139.4,
139.4 and 139.5 MiB. Total idle footprint is **1.02-1.05 GiB**. This table is a
different measurement from the one above -- different load, different moment --
and the two are not comparable row for row.

Worth stating because it is counter-intuitive: dropping five toolchains cut the
image by 1.87 GB but the worker's idle RSS by roughly 170 MiB. The worker's
memory is dominated by the Ruby worker pool (`COUNT` Resque workers, one per
`nproc`), not by the toolchains on disk. The image-size win and the memory win
are separate; do not multiply one by the other.

## 11. VPS sizing

Measured footprint of the whole stack (worker, server, Postgres, Redis) on this
host:

| State | Total |
| --- | --- |
| Idle, after the C++-only image | 1.02-1.05 GiB |
| Peak, during the combined run | ~1.38 GiB |

A **2 vCPU / 4 GB** ARM64 instance leaves comfortable headroom for the page
cache and for `docker compose build`, which runs the isolate build stage and a
full Ruby `bundle install` inside the same VM. 2 GB is enough to run but tight
to build on.

Throughput to size against: **76.59 req/s at concurrency 25** with 200 requests,
on a curve that rises to a knee near concurrency 25 and then degrades -- see
section 9 caveat 3 for the full table and the 400-request confirmations. The
`121.75 req/s` that used to be quoted here is withdrawn: it came from an
undersampled sweep and is not supported by a properly sized run.

The worker pool is sized by `nproc`, and the measured throughput came from one
ARM64 machine, so treat the instance recommendation as proportional: the
compilation cache is what carries throughput here, and it is CPU-count
independent. The worker image is 806 MB on disk / 199 MB content size (section
14). For scale on this host that image is the largest of the three disk
consumers: the Postgres volume reads 69.1 MB, and the compilation cache read
1.4 MB the last time it was sampled -- immediately after being cleared for a
cold benchmark, so treat it as a floor, not a size. The cache is the one that
grows with the number of distinct sources; size it from production rather than
from this host.

## 12. Security implications, per change

| Change | Security effect |
| --- | --- |
| `70c0fe6`, `02e38c7` exec by argv, no shells | **Hardening.** Removes shell interpolation of submission-derived values from the submission path, which removes a command-injection surface. `isolate_job.rb` now has zero backtick execution. |
| `481510b` toolchain fingerprint | **Correctness and isolation.** Before, every language with a leading `VAR=value` in `compile_cmd` shared one cache key, so one language's cached binary could be served for another's submission. The key now includes the resolved compiler path, so a replaced compiler cannot serve a stale binary. |
| `46b57fc` bytes instead of `?` | **Verdict integrity**, and an API behaviour change. Distinct non-UTF-8 outputs no longer compare equal, so they can no longer be graded Accepted. Note the consequence: responses may now carry non-UTF-8 bytes where they were previously lossily transcoded, so clients must tolerate binary payloads. |
| `26284fa` cache compile failures | Cache keys are `SHA256` over source, arch, `language_id`, `compile_cmd`, compiler options, an `additional_files` digest, the runtime version, and the toolchain fingerprint; the entry path is that hex digest, so no user-controlled text reaches a filesystem path. Caching a failure stores only that entry's own `compile_output`. |
| `13e9e80` collapse the queued write | None. Fewer round trips to the same row. |
| `28ce721` language seed filter | **A refusal instead of a broken-looking verdict -- and not a containment boundary.** A submission in a language the image cannot run is now rejected by validation with the language named, instead of being accepted and handed back a shell "not found" as its `compile_output`. Do not read the filter as restricting what a submission can execute: language 89 (`Multi-file program`) ships its own `run.sh`/`run` inside the submission archive and always could, exactly as upstream. Isolate is the boundary here, and that is unchanged. |
| `docker-compose.yml`: server unprivileged | **Hardening.** The public-facing API process no longer holds `privileged: true`, so a compromise of the request path does not arrive with the capability and device-node access that grant carries. The worker keeps it because Isolate needs cgroup delegation and sandbox mounts; that split is the reason the two services exist separately. Verified live, not assumed: `docker inspect` reports server `privileged=false` and worker `privileged=true`, and C++ submissions still return `Accepted`. |
| Resque `FORK_PER_JOB=false` | **Documented tradeoff.** This removes a redundant process boundary between jobs. Untrusted code still never executes in the Ruby process -- Isolate is the boundary -- but a worker process now serves many jobs without a fresh fork, so a leak would persist across jobs. Worth revisiting if the worker's RSS growth in section 10 turns out to be unbounded. |
| Compilation cache overall | A cached binary is reused across submissions by content hash. This is only safe because the key covers the toolchain and the extra files; anyone changing what feeds the key should re-read `CompilationCache.cache_key` first. |

## 13. What was preserved

The brief requires that isolation was not traded away for latency. Verified in
source, not from memory:

- **`-d /etc:noexec`** -- present in `sandbox_argv` (`app/jobs/isolate_job.rb`).
- **Timeouts** -- `cpu_time_limit`, `wall_time_limit`, and the extra-time budget
  still flow into the isolate invocation. The `timeout` workload still returns
  `Time Limit Exceeded`, at 1.1292 s p50 against its own 1 s limit.
- **Process and thread cap** -- `max_processes_and_or_threads: 60` unchanged.
- **Isolation model** -- still Isolate, one box per submission.
- **The worker's privilege grant** -- the API service now runs unprivileged
  (section 14), but the worker still holds `privileged: true`, because Isolate
  needs cgroup delegation and sandbox mounts. The grant moved to the one service
  that uses it; it was not dropped.

One nuance to record rather than discover later: the ARM64 wrapper
(`isolate-wrapper.sh`) rewrites cgroup-only flags into rlimit equivalents,
because this platform has no working cgroup delegation. It drops `--cg`,
`--cg-timing`, and `--no-cg-timing`, and rewrites `--cg-mem=N` into `-m N`.
On the live path `enable_per_process_and_thread_memory_limit` is `false`, so
`memory_limit_args` emits `--cg-mem=N`, which the wrapper turns into `-m N`.
Memory is therefore enforced by `RLIMIT_AS`, a real cap, but it bounds address
space rather than resident memory -- a different guarantee from cgroup
accounting, and one that can mis-report runtimes which reserve large mappings
(notably the JVM and Go). Consequently `--cg` in `base_argv` is currently a
no-op: deterministic and with no live behaviour change, but noisy to a reader.
The C++-only image takes the JVM and Go out of the picture for now, which makes
this latent rather than live -- it matters again the moment a language row is
added back.

## 14. C++-only ARM64 worker image

This is priority 16 from the brief: the image should contain the toolchain the
product actually uses, and nothing else. It touches three files --
`Dockerfile.arm64`, `docker-compose.yml`, and `db/seeds.rb` (`28ce721`) -- and
none of them is on the submission path that the other sections measure.

### What was removed, and what was kept

The apt list used to install five extra toolchains on top of the C++ one:
`python3`, `python3-pip`, `default-jdk`, `nodejs`, `npm`, `golang-go`, `rustc`.
Those names are gone, along with every compatibility symlink that existed to
make the matching language row resolve -- the python, node, java, ruby, rust and
go directories under `/usr/local/`. The comment in the Dockerfile names the
fail-fast consequence and the recovery step, because a reader who wonders why a
Python submission is refused should not have to reconstruct the reasoning.

Kept deliberately, because a seeded language names them:

- `/usr/local/gcc-7.4.0`, `/usr/local/gcc-8.3.0` and `/usr/local/gcc-9.2.0`,
  both `bin` and `lib64`, all pointing at `/usr/bin/gcc`, `/usr/bin/g++` and
  `/usr/lib/aarch64-linux-gnu`. Those links are what make language ids 48/49/50
  (C) and 52/53/54 (C++) interchangeable here despite the version numbers in
  their names -- there is one real compiler, and three rows that reach it.
- `/usr/local/bash-5.0/bin/bash`, for language 46 (Bash (5.0.0)).
- `gcc` and `g++` are named explicitly in the apt list even though
  `build-essential` already pulls them, so the dependency a reader cares about
  is visible in the file instead of inferred from a metapackage.

### Measured effect

| Metric | Before | After |
| --- | --- | --- |
| Image, `docker images` DISK USAGE | 2.68 GB | **806 MB** |
| Image, `docker images` CONTENT SIZE | 672 MB | **199 MB** |
| Worker, idle RSS | 1060 MiB | **866-889 MiB** |
| Server, idle RSS | 227.7 MiB | **126-140 MiB** |
| db, idle RSS | 33.9 MiB | 33.1 MiB |
| redis, idle RSS | 13.02 MiB | 10.1-10.3 MiB |

Both image rows use the same metric on both sides, from the same tool. The image
ID changed from `16e7f156ba75` to `46d4fca75da9`.

The memory rows are idle steady state, sampled minutes apart with no submissions
in flight; the worker ranged 866.1-889 MiB across samples and the server
139.4-139.5 MiB in a run of three consecutive readings. They are a different
measurement from section 10's busy-stack table and are not comparable to it row
for row. The before column is one reading each of the previous image, so treat
it as a point rather than a distribution.

Counter-intuitive, so it is stated rather than left to be discovered: removing
five toolchains cut 1.87 GB off the image and only about 170 MiB off the worker's
idle RSS. The worker's memory is dominated by the Ruby worker pool (`COUNT`
Resque workers, one per `nproc`), not by the toolchains on disk. The image-size
win and the memory win are separate, and neither is a percentage of the other.

Cold start, measured with this image: `docker compose up -d` brings the API up
at **8.66 s**, and the first accepted submission completes at **11.27 s**. A
server-only restart is back in 5.84 s. Rebuild time is not a speedup claim: the
image's layer timestamps bracket its last rebuild at **69 s** (first rebuilt
layer 00:53:24, final layer 00:54:33) with the Ubuntu base reused from Docker's
layer cache. The previous Dockerfile exists in no repository -- see the
version-control caveat -- so there is no before figure to divide by.

### Which languages this image can actually run

The seed used to create all 47 active language rows. Advertising a language
whose interpreter is not in the image is worse than not offering it: the
submission is accepted, and the shell's "not found" comes back as the
`compile_output` of a compilation error, which reads like a broken judge rather
than a refusal.

To find the real set, each language's `compile_cmd` and `run_cmd` was split with
Ruby's `Shellwords.split` and every token that names a path was tested for
existence inside the running worker. Splitting properly matters: a
regular-expression sweep produced false hits from `g++` matching `g`, from the
`//g` inside `LD_LIBRARY_PATH=` prefixes, and from `mkdir` arguments. It also
under-counts entries that need more than one binary -- SQL needs both `sqlite3`
and `cat` -- which is why the probe tests paths rather than package names.

Eleven of the 47 run:

| id | Language |
| --- | --- |
| 43 | Plain Text |
| 44 | Executable |
| 46 | Bash (5.0.0) |
| 48 | C (GCC 7.4.0) |
| 49 | C (GCC 8.3.0) |
| 50 | C (GCC 9.2.0) |
| 52 | C++ (GCC 7.4.0) |
| 53 | C++ (GCC 8.3.0) |
| 54 | C++ (GCC 9.2.0) |
| 85 | Perl (5.28.1) |
| 89 | Multi-file program |

Those eleven ids are now the `SUPPORTED_LANGUAGE_IDS` constant in
`db/seeds.rb`, and the seed skips anything else. The other 36 active rows do not
run here: Assembly (45), Basic (47), C# (51), Common Lisp (55), D (56), Elixir
(57), Erlang (58), Fortran (59), Go (60), Haskell (61), Java (62), JavaScript
(63), Lua (64), OCaml (65), Octave (66), Pascal (67), PHP (68), Prolog (69) --
that one needs a directory on `PATH`, not just a binary -- Python 2.7 (70),
Python 3.8 (71), Ruby (72), Rust (73), TypeScript (74), C (75) and C++ (76) with
Clang, COBOL (77), Kotlin (78), Objective-C (79), R (80), Scala (81), SQL (82),
Swift (83), VB.Net (84), Clojure (86), F# (87), Groovy (88).

### Fail-fast, with the payloads you will see

Live against the running stack, after the rebuild:

```text
GET /languages            -> HTTP 200, exactly the 11 rows above
POST /submissions id 54   -> HTTP 201, {"stdout":"42\n", "status":{"id":3,"description":"Accepted"}}
POST /submissions id 89   -> HTTP 201, a zip whose run.sh echoes hello -> Accepted, that stdout
POST /submissions id 71   -> HTTP 422, {"language_id":["language with id 71 doesn't exist"]}
POST /submissions id 62   -> HTTP 422, {"language_id":["language with id 62 doesn't exist"]}
```

The refusal names the language and never reaches a worker. The row that
disappeared from the seed still exists in the upstream language list, so it can
be restored by adding its package back to the Dockerfile and its id back to
`SUPPORTED_LANGUAGE_IDS` -- both recovery steps are written next to the code
that would need editing.

One path was checked because a submission can outlive the filter that would
reject it: a row created before the filter, pointing at an id that is no longer
seeded. `LanguageSerializer` serializes `id` and `name` straight off the
language row and never dereferences `submission.language`, so such a submission
serializes with `language: null` instead of raising. It is a display outcome,
not a 500.

The filter is not a containment boundary and is not documented as one. A
`Multi-file program` submission (id 89) ships its own `run.sh`/`run` inside its
archive and always could -- that is upstream's project feature, and Isolate, not
the language list, is what contains it. That row is reachable and was checked
rather than assumed: a zip containing an executable `run.sh` that echoes a
string came back `Accepted` with that string as stdout. What the filter fixes is
that the judge no longer advertises 36 languages it cannot run.

### The API service is unprivileged now

`docker-compose.yml` no longer grants `privileged: true` to the `server`
service. The worker keeps it, and needs it: Isolate writes cgroup delegation and
mounts sandbox filesystems, which is exactly the privilege separation the
two-service layout exists to allow. That split is now written down in the
compose file next to the flag, so the next person to read it does not have to
guess which service is supposed to hold the grant.

The claim that the API does not need it was checked in source rather than
assumed: `docker-entrypoint.sh` starts cron and then `exec`s its argument, and
`scripts/server` runs `rails db:create db:migrate db:seed` followed by
`rails s -b 0.0.0.0` (and dumps its environment to `/api/environment`). None of
that touches cgroups, mounts, or sysctls. Verified live afterwards: `docker
inspect` reports `server privileged=false` and `worker privileged=true`, and a
C++ submission still returns `Accepted`. Security implications are in section
12; the seed-filter row there records what the filter is and is not.

### No latency claim

The image was benchmarked in its own run, `benchmarks/results_cpp_only.json`
(run 01:00:23), with the compilation cache cleared first so it would start as
cold as the stored combined run did. Same workload shapes, same harness:

| Workload | p50 before | p50 after | p95 before | p95 after |
| --- | --- | --- | --- | --- |
| tiny_cpp | 0.3205 | 0.1142 | 0.9583 | 1.1819 |
| moderate_cpp | 0.0264 | 0.0416 | 0.4217 | 0.4558 |
| compilation_error | 0.0253 | 0.0606 | 0.3416 | 1.1406 |
| runtime_error | 0.3410 | 0.0414 | 0.4631 | 0.8053 |
| timeout | 1.1292 | 1.2801 | 1.3300 | 1.4217 |
| repeated_submission | 0.0264 | 0.0684 | 0.0370 | 0.8664 |
| multi_run_5 | 0.0336 | 0.0988 | 0.0443 | 0.1486 |

Read this as "not attributable at this sample size" and nothing more, in either
direction. Every row is a cold-cache run, and at three to five samples per
workload the p95 column *is* the largest sample. Look at what actually moved:
five of seven p50 rows and all seven p95 rows sit above the before column, in
the tens of milliseconds -- small, but too consistent to call free -- while
`runtime_error` moved from 0.3410 to 0.0414 s, which is caveat 2's cold-compile
artifact disappearing rather than an effect of the image.

Two things are confounded here and neither is separated by this run: the two
measurements were taken at different times on a machine doing different amounts
of other work, and five samples cannot tell a 20 ms shift from noise. So no
latency improvement is claimed for this change, and no regression is claimed
either -- the statement is that this run does not attribute one. **The value of
this change is image size, build time, and attack surface.** If a latency answer
is needed, re-run both states with n>=50 on a quiet machine; the harness already
supports request counts that size (caveat 3).

One trap worth repeating for whoever re-runs this: the compilation cache is
`tmp/cache/binaries`. The three-character hex directories under `tmp/cache/` are
Rails `FileStore` shards for show payloads, and counting them will make a warm
cache look cold.

## 15. Remaining bottlenecks

Two items that used to head this list are withdrawn rather than renumbered.
The `runtime_error` crash path was a cold-cache artifact with no defect behind
it (section 9 caveat 2), and the concurrency-10 stall was an undersampled sweep
(caveat 3). What actually remains:

1. **Cold compiles, reduced but not gone.** A tiny C++ program used to take
   ~240 ms to compile and link, of which roughly 45 ms is the link; with the
   precompiled header in place the compile is 44 ms on the smallest shape and
   150-205 ms on the realistic ones (section 16). The compilation cache still
   hides the whole of it whenever the same source is submitted again --
   Gator++'s common case -- so its real frequency is "how often a student
   submits something new", and that frequency is now the open question rather
   than the compile time. Re-parsing is no longer the largest single cost on
   the submission path; the fixed per-submission overhead is, and that is what
   priorities 8, 9 and P2 in the brief are about.
2. **Compile and exec still share one worker pool.** A compile-heavy burst and a
   run-heavy burst contend for the same slots, and a compile is ~5x the cost of
   a cache-hit run.
3. **`ENABLE_WAIT_RESULT`** defaults to true and Gator++ uses it, so these
   numbers are the synchronous worst case. The callback or async path was not
   measured.
4. **Throughput falls past a knee, and section 17 puts the pool at 12, not 25.**
   The worker count is `nproc` = 12 Resque workers behind 2 x 12 API slots, so
   the saturated stage opens at 13 concurrent compile-bearing submissions and
   the shipped ladder's opening rung was already past it. Section 17 exhausts
   the attributions -- Postgres, Redis, memory, the cgroup CPU limit and context
   switches are all flat when the knee happens, and the pool's own arithmetic
   reproduces measured throughput within 6% at every rung. What is left is the
   size of the saturated execution window itself, and the instrument for that is
   per-stage counters inside the worker, not a larger pool. Anyone sizing past 12
   concurrent **compile-bearing** submissions should read section 17 first.
5. **`batch_create`** does N independent saves plus N `exists?` queries. The
   brief caps the batch at 20, which bounds it, but it is still N round trips.
6. **An x86-64 binary is still shipped in an ARM64 image.** `judge0-src/bin/telemetry`
   is an `ELF 64-bit LSB pie executable, x86-64`, and `JUDGE0_TELEMETRY_ENABLE`
   is unset in `judge0.conf`, so it is never executed. It is dead weight today
   and a broken promise the moment someone enables it. Either it goes, or it
   gets built for the platform -- this is priority 18's concrete item.

Where each brief priority stands. The rows marked **Done** are the ones the
brief's numbering called for by name; the rest are recorded with the reason they
have not been started, so that "not done" is a decision rather than an omission.

| Priority | Status |
| --- | --- |
| 16 (C++-only ARM64 image) | **Done** -- section 14: 2.68 GB to 806 MB, 36 languages filtered out of the seed, API service unprivileged. |
| 14 (callbacks) | Recommended as YAGNI. `ENABLE_CALLBACKS` is unset and `callback_url` is unused by Gator++. |
| 12 (drop internal Base64) | Not started. Columns are already `text`, with one `binary` for `additional_files`. |
| 15 (compile/exec slot scheduler) | Not started -- still bottleneck 2. |
| 17 (Rust execution plane) | Long-term, not started. |
| 18 (ARM64-native validation) | Not started. Concrete item: the x86-64 `bin/telemetry` above. |
| P1 (precompiled headers) | **Done** -- section 16: 2.455x on the smallest C++ shape and 1.29-1.40x on realistic ones, CPU falling in proportion to wall, no measurable memory cost. |
| 10 (hot/cold status split), 11 (remainder), 13 (SSE remainder), 19 (retention) | Not started. |

## 16. Precompiled headers

**Status: shipped and measured.** `cc32d7d` in `judge0-src/` adds the gate and
the compiler flag; `0c390c3` at the fork root builds the header into the image
and adds the two container checks. This section replaces the proposal that used
to stand here, and keeps the reasoning that produced the design.

### What the probe established, and one thing it got wrong

A cold compile is the only remaining cost of that size on the submission path
(section 15, bottleneck 1). The optimisation is to precompile the header that
costs the most to parse and stop re-parsing it for every submission. The probe
that justified it, `benchmarks/pch_probe.sh`, ran on g++ 11.4.0 inside the
container:

| Configuration | Probe time |
| --- | --- |
| `-O0 -pipe`, full compile and link | 247 / 289 / 190 ms (~240 ms) |
| `-O0 -c`, compile only | 185 / 139 / 163 ms (~160 ms) |
| link only | 50 / 43 / 47 ms (~45 ms) |
| `-Og`, full compile and link | 340 / 226 / 209 ms -- **worse than `-O0`** |
| `<iostream>` PCH, one-time build | 477 ms |
| full compile and link with the `<iostream>` PCH | 76 / 83 / 93 ms (~85 ms) |
| `<bits/stdc++.h>` PCH, one-time build | 6,618 ms, 116 MB |

**Every timing in that table was taken with `-H` on the compile command, and
`-H` is not free.** It makes GCC print every header it opens, which is why the
probe used it -- GCC marks a precompiled header it consumed with `!` -- but it
costs more the more headers there are to print. Measured on its own later, `-H`
more than doubles the compile it is attached to: 121 ms without it, 258 ms with
it, same source, same flags. So the probe's **absolute times are probe times,
not production compile times**, and they are not comparable to the paired
numbers further down this section. Its *shape* is what the design used, and the
shape held. Its oracle is a fact about which file GCC read rather than a timing,
so that part is unaffected.

Three decisions came out of it and all three survived:

- **Keep `-O0`.** At this program size `-Og` averages 258 ms against `-O0`'s
  242 ms and peaks at 340 ms: it costs more to compile while buying optimisation
  for a program that runs for microseconds. This workload is judged on feedback
  latency.
- **`<bits/stdc++.h>` is a trap here.** 116 MB and 6.6 s to build, for a header
  the C++ path does not need. `<iostream>`, at 26 MB, is the target.
- **Linker speedups are not available.** `lld` is not installed in this image,
  so any `fuse-ld=lld` timing would be a failed compile rather than a fast one.

### What was built

Three pieces, in the order they take effect.

**1. The header, built into the image** (`Dockerfile.arm64`). The image compiles
its own `/usr/include/c++/11/iostream` with `g++ -x c++-header` into
`/usr/local/pch/c++/iostream.gch` -- 25,962,452 bytes, root-owned `0644` -- and
writes `pch.sha256` beside it:

```
50479ac05a5cda301555edd09e45e92ac9f5d90da1a50facd6debf3a57909540  iostream.gch
```

It is built in the **last** image layer on purpose. A header built in an earlier
layer against a different toolchain layer produced a different digest; the file
that ships has to be the one the shipped compiler accepts, and the digest is how
the worker knows it is.

**2. The gate** (`judge0-src/app/services/pch.rb`). The worker offers the
include path only after every entry in `pch.sha256` has been re-hashed and
matched against the file it names. A missing manifest, an empty one, a short
read, an unreadable file or a digest mismatch all answer "no PCH" and the
compile proceeds exactly as it did before. The result is memoised per process,
which is why the two supported ways to change it are a rebuild or a worker
restart, and why disabling it in a hurry means deleting the manifest rather than
replacing the header.

**3. The flag** (`judge0-src/app/jobs/isolate_job.rb`). `-I/usr/local/pch/c++`
is appended to the C++ compile command string only, and before `ExecPlan.parse`
runs, so `ExecPlan` remains the single parser for everything the sandbox will
execute and its round-trip check still covers the whole command.

### Why a damaged PCH cannot break a submission

This is the only real risk in the change. GCC treats a truncated `.gch` as a
**hard error** (`rc=1`), and the worker would report that to the student as
though their program were wrong. That is why the check happens *before* the flag
is passed rather than after a failed attempt: there is no path where a bad
header reaches a student's compile.

Flag mismatches do not need the gate. GCC silently ignores a PCH built with a
different `-O` level, standard or feature flags and re-parses the headers the
ordinary way, which `check_pch.sh` exercises directly with `-O2`,
`-std=c++11` and a PCH built for the wrong language. Only a *damaged file* is
dangerous, and only the digest check catches it.

`checks/check_pch.rb` tests the gate against real files in temporary
directories, including a truncated header and a manifest with a forged digest.
`checks/check_pch.sh` proves the same thing through a real Isolate compile in
the container, and additionally that the shipped PCH is the one the manifest
claims and that the binary it produces is ARM64. Recovery from a suspect PCH is
`docker compose up -d --build worker`.

### The effect on a compile

The obvious way to measure this -- a block with the PCH, then a block without --
does not work on this machine. Two identical API-level passes taken back to back
came out up to 2.4x apart on a shape a precompiled header *cannot* affect (the
evidence is under "End-to-end" below). The host drifts by more than the effect.

`benchmarks/pch_paired.sh` therefore alternates the two conditions **run by
run** inside one Isolate box, with the compiler, flags, limits and PATH the
worker uses, and reports the median of the per-run ratios. Each with-PCH compile
is paired with its immediate without-PCH neighbour, so a slow minute lands in
both halves of every pair instead of on one block. `-H` is passed only in a
separate oracle pass per case and condition, never on a timed run, for the
reason above.

The fifth case is the control: a program with no includes at all, which no
precompiled header can help, run through the identical machinery. Its ratio is
the floor of what the method can resolve. `benchmark_pch_paired.py` refuses to
report a run whose oracle contradicts it or whose control moves outside
0.90-1.10x.

30 timed compiles per case per condition, `benchmarks/results_pch_paired.json`,
`-O0`, in-box wall and whole-container CPU:

| Case | Wall without | Wall with | Wall ratio | CPU without | CPU with | CPU ratio |
| --- | --- | --- | --- | --- | --- | --- |
| `minimal_iostream` | 108.0 ms | 44.0 ms | **2.455x** | 111.0 ms | 46.0 ms | 2.407x |
| `gator_student` | 209.0 ms | 149.5 ms | 1.401x | 216.0 ms | 156.0 ms | 1.385x |
| `template_heavy` | 267.0 ms | 204.0 ms | 1.302x | 281.5 ms | 218.0 ms | 1.291x |
| `several_headers` | 251.0 ms | 195.0 ms | 1.287x | 258.0 ms | 201.0 ms | 1.279x |
| `no_include` (control) | 18.0 ms | 18.0 ms | 1.000x | 20.0 ms | 19.5 ms | 1.000x |

The same measurement at 20 repetitions (`results_pch_paired_reps20.json`) gives
2.414 / 1.402 / 1.299 / 1.279 / 1.000 by wall and 2.372 / 1.377 / 1.285 / 1.267
/ 1.000 by CPU -- the two runs agree within 1.7% at every shape, and the control
is exactly 1.000x in both.

So: **2.455x on the smallest program a student can write, and 1.29-1.40x on
realistic ones.** The `2.8x` figure that used to stand in this section is not
reproduced and should not be quoted. Two things account for the difference and
both are corrections rather than regressions: the old figure came from probe
runs carrying `-H`, and the honest comparison alternates the conditions instead
of comparing two blocks on a host that drifts.

Every included shape consumed the PCH in the with-PCH condition and the plain
header in the without-PCH condition, verified by the oracle pass, and every
compile exited 0. The control shape costs nothing measurable: 18.0 ms either
way.

### Does CPU fall in proportion to wall time?

This is the brief's explicit question, so here it is as a ratio of ratios.
`cpu_ms` is the whole worker container's CPU over the run (user + system, from
the cgroup), so it includes Isolate's setup and the driver's own forks -- the
CPU a VPS actually spends, not the compiler's internal figure.

| Case | Wall ratio | CPU ratio | CPU as a share of the wall saving |
| --- | --- | --- | --- |
| `minimal_iostream` | 2.455x | 2.407x | 98.1% |
| `gator_student` | 1.401x | 1.385x | 98.9% |
| `template_heavy` | 1.302x | 1.291x | 99.2% |
| `several_headers` | 1.287x | 1.279x | 99.4% |

**Yes -- CPU falls in proportion to wall time, to within 2%, and the residual
leans the same way in all four cases: CPU falls very slightly less than wall.**
That is the expected direction. The PCH removes parsing work, which is CPU work,
so the two should track almost exactly; what does not shrink is the fixed cost
around the compile -- Isolate's setup, the process spawn, the filesystem work --
which is a larger share of the shorter compile. In millisecond terms the saving
is 64 ms and 65 ms of wall and CPU on `minimal_iostream`, and 56 ms and 57 ms on
`several_headers`: the two move together almost ms for ms.

An optimisation that cut wall time by waiting on I/O would show CPU falling much
*less* than wall. This one does not, which is the evidence that it is removing
real work rather than reordering it.

### Peak memory

The 26 MB header is a concern worth measuring, because a compile that maps it
must not multiply that by the number of concurrent compiles. Sampled from the
container's `memory.current` while each shape's compiles ran
(`benchmarks/results_pch_pch_on_b.json`):

| State | Worker container memory |
| --- | --- |
| Idle, freshly restarted | 835.1 MiB |
| Peak with the PCH | 1,099.3 MiB (+264 MiB) |
| Peak without the PCH | 1,123.2 MiB (+288 MiB) |

The PCH adds **nothing measurable** to peak memory. The file is mapped
read-only, so its pages are shared by every concurrent compile rather than
copied per submission. These are the worker container's cgroup readings and are
not comparable to section 10's RSS figures, which measure the whole stack a
different way; the +264 MiB above idle is compile working set, not the header.

### End-to-end latency, and why this host cannot resolve it

The honest result here is a **failed measurement**, and it is worth recording so
that nobody repeats it or quotes a number out of it. Three full API-level passes
were taken, each on the same five shapes with cold sources, with a restart
between them: with the PCH, without it, and with it again. The third pass is a
sentinel: it repeats the first condition, so the gap between the two tells you
what the host did on its own.

| Shape | PCH on (pass 1) | PCH off | PCH on (pass 2) |
| --- | --- | --- | --- |
| `minimal_iostream` | 306.9 ms | 250.1 ms | 206.8 ms |
| `gator_student` | 446.2 ms | 325.6 ms | 312.9 ms |
| `template_heavy` | 548.2 ms | 427.5 ms | 449.2 ms |
| `several_headers` | 949.9 ms | 424.3 ms | 391.3 ms |
| `no_include` (control) | 351.0 ms | 170.5 ms | 200.2 ms |
| cold throughput, c=25 | 5.96 req/s | 9.35 req/s | 10.15 req/s |

The two passes with the PCH installed are the *same condition*, and the control
shape cannot be affected by a precompiled header at all. They came out 351.0 ms
and 200.2 ms apart -- a 1.75x difference on a shape with no includes -- and
`several_headers` is 2.4x apart. **The method's own error is larger than the
effect being measured**, so no end-to-end latency claim is made in either
direction, and the p50/p95/p99 columns of the summary table below stay empty
for this row. The confounding variable is visible in the same data: pass 1 ran
on a worker that had been up for twenty minutes and reported 1,102 MiB idle,
while passes 2 and 3 ran on freshly restarted workers at 835 MiB. The host and
the container's own accumulated state both moved.

What can be said without measuring it twice is a composition argument, and it is
the reason this does not matter as much as it looks. Everything outside the
compile -- the API, Redis, Resque, Isolate setup, the run phase -- is untouched
by the change, so the end-to-end effect is bounded above and below by the
compile effect already measured: on `minimal_iostream` the PCH removes 64 ms of
wall from a submission whose end-to-end p50 here is roughly 200 ms, so the
end-to-end improvement cannot exceed about 1.3x on that shape, and it is smaller
for every other shape because the compile is a smaller share of it. **The 2.455x
is a compile-stage result and must not be restated as a submission latency
result.**

### Where this leaves the numbers

The table the brief asks for, in the brief's shape. Rows are cumulative states
of the system, not increments, and a cell is filled only where a measurement
supports it.

| Version | p50 | p95 | p99 | CPU/submission | req/s | RSS |
| --- | --- | --- | --- | --- | --- | --- |
| current verified (section 9 caveat 3) | 0.3096 s | 0.4356 s | -- | -- | **76.59 @ c=25** | 1.00 GiB |
| + production PCH | not resolvable here | not resolvable here | -- | compile CPU down 1.29-2.41x | 76.59 unchanged (no compile on a hit) | +0 MiB measured |
| + scheduler changes | not built | | | | | |
| + batch optimization | not built | | | | | |
| + other measured improvements | not built | | | | | |

Three notes on that row, because each is easy to read wrongly:

1. **The 76.59 req/s does not move.** That figure is compilation-cache-hit
   throughput -- the same source re-submitted -- and a PCH cannot speed up a
   submission that does not compile. It is unaffected, not improved.
2. **Cold-compile throughput is a different regime and is reported separately.**
   At concurrency 25 with 200 *distinct* sources it was 9.35 req/s without the
   PCH and 10.15 with it, but the control shape moved 1.75x between the passes
   those numbers came from, so this is not a resolved improvement either. It is
   not a regression, and it is the number to re-measure on a quiet machine.
3. **`CPU/submission` is two different quantities.** The section's headline
   saving is on the compile; the compiled program's own runtime is unchanged,
   because a precompiled header changes what the compiler has already parsed,
   not the code it emits.

The ceiling stated in the original proposal still holds and is now measurable: a
PCH only helps a cache *miss*, and the compilation cache already serves
Gator++'s common case of a repeated source. So the number that decides whether
the 26 MB and the four commits were worth it is not in this section at all -- it
is **how often a cache miss actually happens in production**, which the brief
asks for separately as priority P6. Until that is measured, the defensible
statement is the narrow one: a compile that misses the cache is 1.29-2.46x
cheaper for the same output, and a compile that hits it is unchanged.

---

### Version-control caveat

**This gap is closed**, as of `1c301ec`. There are now two repositories, and
each one owns half of the project:

| Repository | Holds | Commits |
| --- | --- | --- |
| `judge0-src/` | the Rails application | the eight application commits, ending `28ce721`, then `cc32d7d` |
| the fork root | `Dockerfile.arm64`, `isolate-wrapper.sh`, `docker-compose.yml`, `judge0.conf`, `checks/`, `benchmarks/`, `README.md`, `LICENSE`, and this report | `1c301ec` onward |

The fork root tracks 43 files: the compose stack, the sandbox wrapper, the image
definition, the eleven checks, the benchmark scripts that produced every number in
this report, the raw result records they wrote, and this document. Both
repositories are on `master`.

Why this mattered is worth keeping on the record even though it is fixed. The
previous `Dockerfile.arm64` -- the one with the five extra toolchains -- exists
in no repository, so section 14 can report the current image's 69 s rebuild but
has no before figure to divide by. The same gap is why `db/seeds.rb` had to be
committed on its own in `28ce721` while the image it depends on was not. And it
is the direct reason the `2.8x` that used to head section 16 could not be
re-derived: the probe script that produced it had been edited since, and with no
history there was nothing to say what it had actually run when.

Three things are deliberately outside both repositories: the Docker image and
the compilation cache are build and runtime artifacts, and the Postgres and
Redis volumes are data. Both reproduce from the two repositories plus
`docker compose up -d --build`.

## 17. What bounds throughput, and what does not

**Status: the structure is attributed; the absolute numbers of the saturated
stage are not, and this section says so as a finding rather than leaving it as
an omission.** Section 9 caveat 3 measured *that* the curve falls past a knee.
This section asks why, and the answer is not a queue, a store, a lock or a
cgroup limit. It is the shape of the worker pool plus how long one submission
occupies a worker -- and the second half of that sentence is where the remaining
unknown sits.

The three probes behind this section are scratch instruments rather than
committed harnesses, so each one's method is given in full below. That is
deliberate: the version-control caveat at the end of section 16 is the record of
what a number costs when its instrument cannot be re-read.

### The pool is 12 workers and 24 request slots

`judge0-src/scripts/load-config:38` starts `COUNT=${COUNT:-$(nproc)}` Resque
workers, and the same file sets `RAILS_SERVER_PROCESSES=2` and
`RAILS_MAX_THREADS=$(nproc)` (`:23-24`), which `judge0-src/config/puma.rb:1-4`
turns into the API server. Inside the worker container `nproc` is 12, so the
stack is **12 workers against 2 x 12 = 24 API request slots**, confirmed live
again this session. Two independent samplers agree at every rung of the ladder.
The redis sampler reports `redis_workers = 12` flat -- read the raw
`samplers.redis.redis.redis_workers` field in the ladder records, not the
flattened `sandbox.redis_workers`, which is null in that file because the
harness read the group off the wrong container until `a8b8d61`. The sandbox
sampler counts `isolate_procs_max` at exactly **2 x min(c, 12)**: 2, 4, 8 and
16 at concurrency 1, 2, 4 and 8, then pinned at **24** from concurrency 16
upward. Two isolate processes per in-flight submission, twelve submissions in
flight -- the sandbox's own ceiling lands on the same 12.

So at most `min(c, 12)` submissions execute at once, and the ladder is staged
like this:

| Stage | Concurrency | What is actually happening |
| --- | --- | --- |
| unsaturated | 1, 2, 4, 8 | every submission gets its own worker; queue wait is tens of ms |
| the boundary | 12 | the pool first runs full |
| supersaturated | 16, 25, 32, 50, 75, 100 | arrivals queue behind the pool; extra concurrency buys nothing |

**This contradicts the premise the shipped brief sizes against.** The brief puts
the knee at concurrency 25 and asks for the mechanism past it. On this fork the
saturated stage opens at 13, so the committed ladder's opening rung at 25 was
already past the knee, and concurrency 50 and 100 are four and eight times the
pool. P2 should be read against 12, not 25.

### One law holds at every rung

Divide the pool depth by the measured execution window and you get the measured
throughput back:

```
throughput (req/s)  =  min(concurrency, 12) / execution_mean (s)
```

| Concurrency | Throughput req/s | `execution_mean` ms | `min(c,12)/exec` | Ratio |
| --- | --- | --- | --- | --- |
| 1 | 2.28 | 418.8 | 2.39 | 1.05 |
| 2 | 3.40 | 567.6 | 3.52 | 1.04 |
| 4 | 3.77 | 1010.0 | 3.96 | 1.05 |
| 8 | 3.77 | 2009.5 | 3.98 | 1.06 |
| 16 | 1.71 | 6651.1 | 1.80 | 1.05 |
| 25 (opening) | 7.17 | 1618 | 7.42 | 1.03 |
| 25 (closing) | 1.14 | 9984 | 1.20 | 1.05 |
| 32 | 1.92 | 5922.8 | 2.03 | 1.06 |
| 50 | 1.85 | 6163.5 | 1.95 | 1.05 |
| 75 | 1.96 | 5782.1 | 2.08 | 1.06 |
| 100 | 2.22 | 5224.0 | 2.30 | 1.04 |

This is Little's law applied to the pool, so it is close to a tautology, and it
is not offered as a discovery. What makes it worth a table is the range it holds
over: the execution window moves **24x** across these rungs -- 419 ms to 9 984 ms
-- and the law still lands within 6% at every one, with the same sign (it
over-predicts slightly, which is the driver's own startup). Nothing else in the
system is a first-order term. The saturated stage therefore has exactly one free
parameter, the execution window, and everything that follows is about what moves
it.

### Where a worker's CPU actually goes

A per-PID sampler read `/proc/<pid>/stat` every 20 ms while the harness's own
cold workload ran, bracketed by the container's exact cgroup CPU window, so the
split could be checked against the whole. It reduces `comm` to a family and
sums each PID's own `utime + stime` delta:

| | c=1, 30 submissions | c=32, 200 submissions |
| --- | --- | --- |
| container cgroup window | 10 629 ms | 97 916 ms |
| sampled per-PID CPU (a lower bound) | 8 040 ms (76%) | 78 830 ms (81%) |
| of it: `ruby3.0` | 4 480 ms (**42.1%**) | 53 220 ms (**54.4%**) |
| of it: the compiler (`cc1plus`, `as`, `ld`) | 3 210 ms (**30.2%**) | 24 450 ms (**25.0%**) |
| of it: this probe's own shells | 340 ms (3.2%) | 1 120 ms (1.1%) |
| sampled CPU **per submission** | **268 ms** | **394 ms** |
| per submission, phased | ruby 149 ms / compile 107 ms | ruby 266 ms / compile 122 ms |

Two readings come out of this, and they point in opposite directions.

**The compiler is a stable quarter to a third of the work, per submission and
across the ladder.** Per-submission compiler CPU barely moves, 107 ms to 122 ms,
while the run gets six times more concurrent. If compile capacity were the thing
that saturates, that column would be the one climbing. It is the flattest number
in the section, so any compile-stage change -- including the precompiled header
of section 16 -- has a 25-30% ceiling on worker CPU and not the submission.

**The Ruby side is where the growth is: 42% of the window at c=1, 54% at c=32,
and 1.47x per submission.** Within the Ruby total, PIDs 55-66 -- the 12 Resque
workers, all children of PID 28 -- own 4 400 of 4 480 ms at c=1 and 53 040 of
53 220 ms at c=32. The two Puma processes cost 20 ms and 40 ms respectively:
**under 0.2% of the window at every level, so the API tier is not in this
picture at all.** "Ruby" here means the workers, and the fixed per-submission
overhead section 16 identified as the largest remaining cost is theirs.

### What is not the limiter

Each of these was measured at every rung of the same ladder, and each one is
flat enough to exclude:

| Candidate | Reading across cold c=1 to c=100 | Verdict |
| --- | --- | --- |
| Postgres | 37 connections, 36 waiting, 1 active -- identical at all eleven rungs; `blks_read = 0`; 0 deadlocks; `xact_rollback = 0` | no headroom consumed, and no growth in demand |
| Redis | `BLPOP` p99 24 µs at c=1, 214 µs at c=8, 242 µs at c=100. The `BLPOP` wait itself *falls*, 151 ms to 0.7-1.7 ms, while commands per submission rise ~2.5x | microsecond-scale queue, and the queue is empty |
| memory | `swap_in_pages = swap_out_pages = 0`, `major_faults = 0`, `disk_read_sectors = 0`; worker peak 1 216 MiB rising to 1 757 MiB and falling to 1 653 MiB at c=100; `mem_available` 4 837-5 062 MiB; `psi_memory_some = 0.0` at every rung | nothing is paging, nothing is close |
| the CPU limit | `nr_throttled = 0.0` at every rung in the worker, db and server cgroups | the container never hit its quota |
| context switches and forks | 743 k to 4.73 M context switches; 2 696 to 14 023 forks, i.e. 70-90 forks per submission | a consequence of the work, not a ceiling on it |
| host pressure | `host psi_cpu_some` 2.03 -> 10.93 -> 7.61% and `worker psi_cpu_some` 0.43 -> 11.00 -> 6.15% agree within ~2 pp | **open** -- see below |

The last row is the one that cannot be closed from here. A container inside the
Docker Desktop VM reads the Mac's steal as its own pressure, so these two fields
cannot be told apart by this instrument. That is the honest state: the
question of how much of the saturated stage is the host rather than the stack
stays open, and no steal figure is asserted.

### The control: the same pool with the compiler removed

The `hit` sweep is the cold sweep with one variable removed. It submits the same
source every time, so every submission is a compilation-cache hit, while the
sandbox still runs and the program still executes. Same image, same 12 workers,
same 24 slots, same Postgres, same Redis, same day:

| Concurrency | Throughput req/s | `cpu_ms_per_submission` | `execution_mean` ms |
| --- | --- | --- | --- |
| 8 | 14.30 | 238 | 167 |
| 16 | 26.62 | 140 | 108 |
| 25 (opening) | 69.47 | 49 | 48 |
| 32 | 28.30 | 115 | 126 |
| 100 | **84.57** | **34.2** | 28 |
| 25 (closing) | 65.06 | 60 | 71 |

Two things follow. First, **the pool is not what bounds the cold run.** With the
compile gone the identical pool carries **84.57 req/s -- 38x the 2.22 req/s of
the cold c=100 rung** -- and it is not even working hard: at `execution_mean` of
28 ms and `cpu_ms_per_submission` of 34 ms, a request occupies a slot for
milliseconds and the pool has room for ~400 req/s. The run is limited by the
100-client driver, not by the system: 84.57 req/s at a 1 203 ms p50 is 102
requests in flight against 100 client slots. 84.57 is a floor, not a ceiling.

Second, this settles P2 in the negative from the other end. No store, no memory
exhaustion, no cgroup throttle and no context-switch ceiling can produce a knee
at 12, and none of them is at a limit when the knee happens. The pool structure
does produce the knee exactly where the arithmetic says it must, and the compile
is the only stage whose removal changes the answer by an order of magnitude.

### Compile width, measured separately

The ladder says how many submissions the stack serves; it does not say how a
burst of compiles behaves, because that is a compile-stage question and needs
its own probe. 96 fixed compiles per level, two repetitions per arm, both arms
reporting zero failures, wall in seconds for the whole batch (the mean of the
two reps):

| Width | Wall s, PCH | Wall s, no PCH | Compiles/s, PCH | Compiles/s, no PCH | PCH saving |
| --- | --- | --- | --- | --- | --- |
| 1 | 15.4 | 22.3 | 6.2 | 4.3 | 1.43x |
| 2 | 7.5 | 11.1 | 12.9 | 8.7 | 1.47x |
| 4 | 4.3 | 6.2 | 22.2 | 15.6 | 1.41x |
| 6 | 3.3 | 4.8 | 29.1 | 20.2 | 1.43x |
| 8 | 3.0 | 4.3 | **32.4** | **22.4** | 1.44x |
| 12 | 3.4 | 4.5 | 28.4 | 21.2 | 1.36x |
| 16 | 3.2 | 4.8 | 30.5 | 20.2 | 1.50x |
| 24 | 3.4 | 5.0 | 28.7 | 19.3 | 1.50x |

**Compile throughput scales to width 8 and then stops, and goes backwards at
width 12** -- which is the pool size, so the two probes agree on where the corner
is. **The PCH advantage survives parallelism**: it holds 1.36-1.50x at every
width, so the section 16 result is a compile-stage result that does not evaporate
when the machine is busy. Do not restate it as a submission-latency ratio.

One number here resists interpretation and is recorded that way. Container CPU
per compile rises from 162 ms to 370-419 ms (PCH) and from 240 ms to 520-625 ms
(no PCH) -- 2.3-2.6x -- once width exceeds the 12 cores. On a shared machine,
CPU per compile under contention is not a constant, and this probe cannot
separate real contention from the host load behind it. The wall column is the
one to use.

### The noise floor, and how to re-run one rung

The same code, the same payload shape and the same container were run again on a
quieter machine, and the saturated rung moved by more than the effect of any
change in this report:

| c=32 | Committed ladder | Fresh re-run | Ratio |
| --- | --- | --- | --- |
| driver wall | 104.3 s | 50.67 s | **2.06x** |
| throughput | 1.92 req/s | 3.95 req/s | 2.06x |
| container CPU per submission | 2 106 ms | 514 ms | **4.1x** |
| `execution_mean` | 5 923 ms | 2 922 ms | 2.03x |
| `queue_wait_mean` | 5 828 ms | 2 898 ms | 2.01x |

The c=1 rung moves the other way and less: wall 13.1 s to 19.35 s (1.48x slower)
while its CPU per request only goes 263 ms to 301 ms (1.14x). That is the
cleanest statement of the noise available -- **per-request cost is stable, wall
time is not.**

The committed sweep itself records the cause. The Mac's load average, read
before each rung, runs **5.38, 7.82, 6.84, 7.08, 9.64, 13.70, 17.32, 17.70,
16.12, 28.86** and 19.42 at the closing rung: the ladder was taken on a host
that was already busy and got busier, which is also why its opening and closing
rungs at the same concurrency differ by 6.3x (7.17 vs 1.14 req/s). The re-run was
taken at load 3.97 (1 min) and 5.48 (15 min).

**Consequence, and it is a constraint on how this report may be read: every
absolute throughput and `cpu_ms_per_submission` in the saturated stage is
host-noise-dominated and must not be quoted as a property of the system.** What
reproduced exactly is the structure -- 12 workers, 24 isolate slots, 37 Postgres
connections, and the law above -- and structure is what a decision should be
sized on.

Re-running one rung needs no scratch script, because the committed harness
already takes both the level and the tag as arguments:

```
python3 benchmarks/benchmark_saturation.py --label drift --levels 32 --total 200 \
    --sweeps cold --nonce-base <a tag no earlier run used>
```

Compare `throughput_req_per_s` and `worker.cpu_ms_per_submission` against the
table above. **"Cold" only means cold with an unused tag**: replaying a saved
`workload_cold_*.json` measures the compilation cache instead, and that mistake
looks like a 20x speedup.

### Three instrument corrections

**`resque_processing_max` is not a concurrency count, and its name invites that
misreading.** It is the harness's count of proctitles matching `Processing`
(`sandbox.resque_processing_max` in `benchmarks/results_saturation_sat.json`);
nothing in this section uses it as a pool depth. A fresh concurrency-1 run of 12
requests, sampled 25 times at 0.4 s with the harness's own
`ps -e -o comm=,args=` and the same two regexes, reads:

```
processing=0 waiting=12   processing=1 waiting=11   processing=2 waiting=10
processing=3 waiting=9    processing=4 waiting=8  <- peak on a c=1 run
processing=3 waiting=9    ...
```

Concurrency 1 cannot have four submissions in flight, so the field is counting
something other than submissions. `processing + waiting` reads 12 in every tick,
which is the pool, and the committed records agree: on the cold ladder the two
means sum to 12.000-12.019 at every rung. (The `hit` records drift to 12.2,
because those runs are short enough that the sampler only caught 24-64 ticks
against the cold ladder's 390 and up. `checks/check_pool_structure.py` asserts
the cold half.) The set of processes carrying a `Processing` title also rotates
between ticks (P63, then P61, then P64, then P65) while `Waiting` falls by the
same amount; the worker map underneath is stable -- PID 55 through 66, twelve
processes, all PPID 28, with `resque-2.6.0: Waiting for 1.13.1` at rest, and
`judge0-src/config/initializers/resque.rb:16` sets `FORK_PER_JOB = "false"`.
The committed c=1 record's `resque_processing_max` is 3.81 mean / 6 max over 63
ticks, and the saturated rungs read 11.4 of 12 with a max of 13 -- a thirteenth
process, which is what a count of titles rather than a count of workers looks
like. **What was measured is that the field counts processes whose proctitle says
`Processing`; why the extra ones carry that title was not proven and is not
guessed at here. Use `isolate_procs_max` (24) and `redis_workers` (12) for pool
readings; both are unambiguous.**

**The queue the sampler watched did not exist, and the queue that does exist is
named after the version.** `SMEMBERS resque:queues` returns `{1.13.1}`: Resque
deletes `resque:queue:<name>` when it drains, so `LLEN resque:queue:default`
never existed and an instrument watching it reads zero forever and looks calm.
The committed ladder is that zero, and it is worth seeing once: `queue_depth`
reads a **max of 0.0 in all 22 records**, saturated rungs included, while the
same sampler's `redis_workers` reads 12 in every one of them.
`load-config:39` sets `QUEUE=${JUDGE0_VERSION}`, which is where the version
string comes from. Fixed in `a8b8d61`; `checks/check_saturation_sampler.py`
reports 11 ok with rc=0, its negative test confirms it fails when the wiring is
broken, and `preflight()` at `benchmark_saturation.py:781` prints the recovery
command rather than leaving a silent zero.

**The per-PID split cannot see the sandbox, and its coverage is the bound.**
`isolate.bin` (67 PIDs seen at c=1, 498 at c=32) and `a.out` read ~0 ms because
they are short-lived and a sample is taken after they exit; at c=32 the effective
tick was ~100 ms rather than the 20 ms requested. **Do not quote an isolate CPU
figure from this data.** The 76% and 81% coverage rows are the honest form of the
measurement: the sampler accounts for three quarters to four fifths of the
window, and the remainder is largely the short-lived processes it never caught.

### What would settle what is left

The remaining question is narrow and can be stated exactly: **a submission's
execution window is 2 922 ms at 12-way concurrency while its own CPU is 394 ms,
and 609 ms while its CPU is 268 ms at concurrency 1.** The window inflates 4.8x
while the CPU inflates 1.3x, so most of the saturated stage is time that is not
computing, on a pool that is not CPU-bound. Two candidates survive everything
above -- the host descheduling the container, which cannot be resolved from
inside a Docker Desktop VM, and something in the compile pathway that blocks
rather than burns CPU.

The instrument that separates them is **per-stage counters inside the worker**:
compile idle/total, exec idle/total, queue wait, per request. A `perf`-class
profile of a single submission, taken stage by stage, would answer it too. Note
what the instrument response is *not*: it is not a larger pool. Raising
`COUNT` moves the knee from 12 to somewhere else without explaining this one,
which is why priority 15's slot scheduler is worth building only after the
counter exists to tell it what to schedule against.
