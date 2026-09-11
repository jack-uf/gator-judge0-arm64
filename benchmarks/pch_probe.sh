#!/bin/sh
# PCH behaviour probe. Runs inside the ARM64 worker container as root.
#
# Answers three questions before any production code is written:
#   1. Does placing iostream.gch on the include path actually get used, and how
#      much time does it save on real compile commands?
#   2. What happens when the precompiled header does not match the compile
#      command's flags -- silent fallback, warning, or hard error? A hard error
#      would make this optimisation unsafe for student code, which may pass
#      compiler_options.
#   3. What happens when the .gch is corrupt or unreadable?
#
# `-H` is the oracle: GCC marks a precompiled header it actually consumed with
# a leading '!', and an ordinary header with 'x'/'..'.
#
# Usage: docker exec -i -u root <worker> sh -s < benchmarks/pch_probe.sh
set -u

PCHDIR=/usr/local/pch/c++
WORK=$(mktemp -d)
mkdir -p "$PCHDIR"

cat > "$WORK/io.cpp" <<'EOF'
#include <iostream>
int main() { std::cout << "hi\n"; }
EOF

cat > "$WORK/many.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <map>
#include <sstream>
int main() {
  std::vector<std::string> v{"b", "a"};
  std::sort(v.begin(), v.end());
  std::map<std::string, int> m;
  m[v[0]] = 1;
  std::ostringstream os;
  os << v[0] << m.size();
  std::cout << os.str() << "\n";
}
EOF

cat > "$WORK/tmpl.cpp" <<'EOF'
#include <iostream>
template <int N> struct F { enum { v = N * F<N - 1>::v }; };
template <> struct F<0> { enum { v = 1 }; };
template <typename T> T twice(T x) { return x + x; }
int main() { std::cout << F<10>::v + twice(21) << "\n"; }
EOF

cat > "$WORK/plain.cpp" <<'EOF'
int main() { return 0; }
EOF

cat > "$WORK/math.cpp" <<'EOF'
#include <cmath>
int main() { return (int)std::sqrt(16.0) - 4; }
EOF

# Milliseconds for one compile, and whether the PCH was consumed.
probe() {
  label=$1
  src=$2
  shift 2
  start=$(date +%s%N)
  out=$(g++ "$@" -H -o "$WORK/out.bin" "$src" 2>&1)
  rc=$?
  end=$(date +%s%N)
  ms=$(( (end - start) / 1000000 ))
  if echo "$out" | grep -q '^!'; then used=PCH; else used=header; fi
  warn=$(echo "$out" | grep -ci 'not used\|invalid\|error' || true)
  printf '%-28s %-8s %6s ms  rc=%s  diag=%s\n' "$label" "$used" "$ms" "$rc" "$warn"
}

echo "== compiler =="
g++ --version | head -1
g++ -dumpmachine
echo "== PCH build =="
bstart=$(date +%s%N)
g++ -x c++-header /usr/include/c++/11/iostream -o "$PCHDIR/iostream.gch"
bend=$(date +%s%N)
echo "iostream.gch built in $(( (bend - bstart) / 1000000 )) ms, size $(du -h "$PCHDIR/iostream.gch" | cut -f1)"
echo "== timing, no PCH on the include path =="
probe "io (no pch)"      "$WORK/io.cpp"
probe "many (no pch)"    "$WORK/many.cpp"
probe "tmpl (no pch)"    "$WORK/tmpl.cpp"
probe "plain (no pch)"   "$WORK/plain.cpp"
probe "math (no pch)"    "$WORK/math.cpp"
echo "== timing, PCH available via -I =="
probe "io (pch)"         "$WORK/io.cpp"   -I"$PCHDIR"
probe "many (pch)"       "$WORK/many.cpp" -I"$PCHDIR"
probe "tmpl (pch)"       "$WORK/tmpl.cpp" -I"$PCHDIR"
probe "plain (pch)"      "$WORK/plain.cpp" -I"$PCHDIR"
probe "math (pch)"       "$WORK/math.cpp" -I"$PCHDIR"
echo "== flag mismatch: does it error or fall back? =="
probe "io -std=c++11"    "$WORK/io.cpp"   -I"$PCHDIR" -std=c++11
probe "io -std=c++14"    "$WORK/io.cpp"   -I"$PCHDIR" -std=c++14
probe "io -std=gnu++17"  "$WORK/io.cpp"   -I"$PCHDIR" -std=gnu++17
probe "io -O2"           "$WORK/io.cpp"   -I"$PCHDIR" -O2
probe "io -O3"           "$WORK/io.cpp"   -I"$PCHDIR" -O3
probe "io -DDEBUG=1"     "$WORK/io.cpp"   -I"$PCHDIR" -DDEBUG=1
probe "io -g"            "$WORK/io.cpp"   -I"$PCHDIR" -g
probe "io -fno-exceptions" "$WORK/io.cpp" -I"$PCHDIR" -fno-exceptions
echo "== with -Winvalid-pch, the same mismatches speak up =="
probe "io -O2 -Winvalid-pch" "$WORK/io.cpp" -I"$PCHDIR" -O2 -Winvalid-pch
echo "== corrupt PCH =="
mkdir -p "$WORK/bad"
head -c 4096 "$PCHDIR/iostream.gch" > "$WORK/bad/iostream.gch"
probe "io (corrupt pch)" "$WORK/io.cpp" -I"$WORK/bad"
printf 'not a pch at all\n' > "$WORK/bad2.gch"
mkdir -p "$WORK/bad2"
cp "$WORK/bad2.gch" "$WORK/bad2/iostream.gch"
probe "io (garbage pch)" "$WORK/io.cpp" -I"$WORK/bad2"
echo "== wrong-language PCH (C header compiled as C++ header) =="
mkdir -p "$WORK/bad3"
g++ -x c-header /usr/include/stdio.h -o "$WORK/bad3/iostream.gch" 2>/dev/null || echo "(could not build)"
probe "io (stdio pch)" "$WORK/io.cpp" -I"$WORK/bad3"
echo "== empty header PCH built with -O2, used from a -O0 compile =="
mkdir -p "$WORK/bad4"
g++ -O2 -x c++-header /usr/include/c++/11/iostream -o "$WORK/bad4/iostream.gch"
probe "io (O2 pch -> O0)" "$WORK/io.cpp" -I"$WORK/bad4"
echo "== what a plain -I compile of the real header emits, for comparison =="
g++ -I"$PCHDIR" -H -o "$WORK/out.bin" "$WORK/io.cpp" 2>&1 | sed -n '1,6p'
rm -rf "$WORK"
