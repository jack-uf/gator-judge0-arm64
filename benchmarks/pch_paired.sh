#!/bin/sh
# Paired measurement of what the precompiled header does to the compile itself.
#
#   docker compose exec -T -u root worker sh -s < benchmarks/pch_paired.sh
#
# The cases have to be in the box already; `benchmark_pch_paired.py` writes them
# and reads this script's output back.
#
# The two conditions are alternated run by run rather than measured as two
# blocks. This host's compile speed drifts by more than the effect being
# measured -- two identical back-to-back API passes came out 3x apart -- so a
# "with" block followed by a "without" block would compare the host's mood as
# much as the compiler's work. Alternating puts each condition next to its
# counterpart, and the summary is a median of per-run ratios.
#
# Prints one TSV line per compile:
#   <case> <withpch|withoutpch> <timed|oracle> <wall_ms> <cpu_ms> <pch|header> <exitcode>
#
# Only `oracle` runs pass `-H`. `-H` makes GCC print every header it opens, which
# costs real time and costs *more* the more headers are parsed -- so passing it
# on the timed runs would inflate the without-PCH condition more than the
# with-PCH one and manufacture a speedup. The oracle runs exist only to prove
# which form was consumed, and are excluded from the summary.
#
# `cpu_ms` is the whole container's CPU over the run, read from the cgroup
# before and after. That includes this shell and Isolate's own setup, which is
# the point: it is the CPU the VPS spends, not the compiler's internal figure.
set -u

PCHDIR=/usr/local/pch/c++
CXX=/usr/local/gcc-9.2.0/bin/g++
REPS=${REPS:-20}
BOX=""
cleanup() {
  [ -n "$BOX" ] && isolate -b "$BOX" --cleanup >/dev/null 2>&1
}
trap cleanup EXIT

# The driver has usually already prepared the cases, and `--init` empties a box
# that already exists -- initialising it here would delete them. Only a
# hand-run without BOX_ID looks for a box of its own.
BOX=${BOX_ID:-}
if [ -z "$BOX" ]; then
  for candidate in 989 988 987 986 985 984 983 982 981 980 979 978; do
    if isolate -b "$candidate" --init >/dev/null 2>&1; then
      BOX=$candidate
      break
    fi
  done
fi
if [ -z "$BOX" ]; then
  printf 'FAIL: no free Isolate box in 978-989\n' >&2
  exit 1
fi
BOXDIR="/var/local/lib/isolate/$BOX/box"
CASES="$BOXDIR/cases"
if [ ! -d "$CASES" ]; then
  printf 'FAIL: no cases in %s\n' "$CASES" >&2
  exit 1
fi

# The same flags, limits and PATH the worker uses for a compile. `-H` is this
# script's own oracle: GCC marks a precompiled header it consumed with '!'.
ENVARGS="-E HOME=/tmp -E PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

run_one() { # case, include path ("" for none), timed|oracle
  case_name=$1
  include=$2
  mode=$3
  cp "$CASES/$case_name.cpp" "$BOXDIR/main.cpp"
  rm -f "$BOXDIR/out.bin" "$BOXDIR/err.txt"

  hflag=
  [ "$mode" = oracle ] && hflag=-H

  # The cgroup's first line is `usage_usec N`, so one `read` gets it with no fork.
  read -r _ cpu0 < /sys/fs/cgroup/cpu.stat
  started=$(date +%s%N)
  isolate -b "$BOX" --stderr-to-stdout -i /dev/null \
    $ENVARGS -t 20 -x 0 -w 20 -k 64000 -p60 -m 512000 -f 4096 \
    --run -- "$CXX" -O0 -pipe $include $hflag -o out.bin main.cpp > "$BOXDIR/err.txt" 2>&1
  exitcode=$?
  finished=$(date +%s%N)
  read -r _ cpu1 < /sys/fs/cgroup/cpu.stat

  # Only the oracle run says anything about which header form was used; on a
  # timed run there is no `-H` output to read.
  used=-
  if [ "$mode" = oracle ]; then
    used=header
    if grep -q "^! $PCHDIR/iostream.gch$" "$BOXDIR/err.txt" 2>/dev/null; then
      used=pch
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$case_name" \
    "$( [ -n "$include" ] && echo withpch || echo withoutpch )" \
    "$mode" \
    "$(( (finished - started) / 1000000 ))" \
    "$(( (cpu1 - cpu0) / 1000 ))" \
    "$used" "$exitcode"
}

for path in "$CASES"/*.cpp; do
  case_name=$(basename "$path" .cpp)
  run_one "$case_name" "-I$PCHDIR" oracle
  run_one "$case_name" "" oracle
  i=0
  while [ "$i" -lt "$REPS" ]; do
    run_one "$case_name" "-I$PCHDIR" timed
    run_one "$case_name" "" timed
    i=$((i + 1))
  done
done
