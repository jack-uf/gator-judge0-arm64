#!/bin/sh
# End-to-end checks for the precompiled header, in the shipped ARM64 image.
#
#   docker compose exec -T -u root worker sh -s < checks/check_pch.sh
#
# The host check (`checks/check_pch.rb`) proves the gate refuses a damaged PCH.
# This one proves the things only the image can answer:
#
#   * the installed PCH matches the digest manifest shipped beside it;
#   * a compile run the way the worker runs it -- inside Isolate, with the same
#     flags, sandbox limits and PATH -- actually consumes the PCH, which is what
#     shows Isolate's read-only view of the host root covers the PCH directory;
#   * the surprising cases stay harmless: a student compiler flag that
#     invalidates the PCH, a PCH built for the wrong language, and no PCH at all
#     all fall back to the ordinary header parse instead of failing;
#   * the binary produced with the PCH is an ARM64 executable that runs.
#
# Everything the sandbox has to read is placed in the box: Isolate mounts its own
# /tmp over the host's, so a temporary directory on the host would be invisible
# from inside the compile.
set -u

PCHDIR=/usr/local/pch/c++
CXX=/usr/local/gcc-9.2.0/bin/g++
WORK=$(mktemp -d)
BOX=""
BOXDIR=""
failures=0

ok() { printf 'ok: %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1"; }

expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want $2, got $3)"; fi
}

cleanup() {
  [ -n "$BOX" ] && isolate -b "$BOX" --cleanup >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# A free Isolate box. The worker derives its box id from the submission id
# (submission.id % 1000), so the top of the range is taken only by a database
# with hundreds of submissions; the first box that initialises wins.
# ---------------------------------------------------------------------------
for candidate in 999 998 997 996 995 994 993 992 991 990; do
  if isolate -b "$candidate" --init >/dev/null 2>&1; then
    BOX=$candidate
    break
  fi
done
if [ -z "$BOX" ]; then
  printf 'FAIL: no free Isolate box in 990-999; is a submission running?\n'
  exit 1
fi
BOXDIR="/var/local/lib/isolate/$BOX/box"
ok "using Isolate box $BOX"

# ---------------------------------------------------------------------------
# 1. The installed PCH is the one the manifest describes.
# ---------------------------------------------------------------------------
if (cd "$PCHDIR" && sha256sum -c pch.sha256 >/dev/null 2>&1); then
  ok "the installed PCH matches its digest manifest"
else
  bad "the installed PCH does not match its digest manifest"
fi

# The gate is the worker's own code, loaded the same way the worker loads it.
cat > "$WORK/gate.rb" <<'RUBY'
require "/api/app/services/pch"
directory = ARGV[0] == "-" ? nil : ARGV[0]
answer =
  case ARGV[1]
  when "usable"      then (directory ? Pch.usable?(directory) : Pch.usable?) ? "yes" : "no"
  when "args"        then (directory ? Pch.include_args(directory) : Pch.include_args).join(" ")
  when "fingerprint" then directory ? Pch.fingerprint(directory) : Pch.fingerprint
  end
print(answer)
RUBY

gate() { # directory ("-" for the installed one) then question
  ruby "$WORK/gate.rb" "$1" "$2" 2>&1
}

expect "the installed PCH passes the worker's gate" \
  "yes" "$(gate - usable)"
expect "the gate offers the include path the image installed" \
  "-I$PCHDIR" "$(gate - args)"
case "$(gate - fingerprint)" in
  pch:*) ok "the installed PCH has a content fingerprint for the compile cache" ;;
  *) bad "the installed PCH has no content fingerprint ($(gate - fingerprint))" ;;
esac

# A damaged copy of the real PCH, manifest and all, must be refused. This is the
# case that matters: truncation is a hard compiler error, so offering it would
# turn a working submission into a student-visible compile failure.
mkdir -p "$WORK/cut" "$WORK/size" "$WORK/bare"
cp "$PCHDIR/iostream.gch" "$WORK/cut/iostream.gch"
cp "$PCHDIR/pch.sha256" "$WORK/cut/pch.sha256"
truncate -s 4096 "$WORK/cut/iostream.gch"
expect "a truncated copy of the installed PCH is refused" \
  "no" "$(gate "$WORK/cut" usable)"

cp "$PCHDIR/iostream.gch" "$WORK/size/iostream.gch"
cp "$PCHDIR/pch.sha256" "$WORK/size/pch.sha256"
printf 'X' | dd of="$WORK/size/iostream.gch" bs=1 seek=1024 conv=notrunc status=none
expect "a same-length edit of the installed PCH is refused" \
  "no" "$(gate "$WORK/size" usable)"

cp "$PCHDIR/iostream.gch" "$WORK/bare/iostream.gch"
expect "an unmanifested PCH is refused" "no" "$(gate "$WORK/bare" usable)"

# ---------------------------------------------------------------------------
# 2. The production compile, inside Isolate.
# ---------------------------------------------------------------------------
cat > "$WORK/io.cpp" <<'CPP'
#include <iostream>
int main() { std::cout << "hi\n"; return 0; }
CPP

cat > "$WORK/many.cpp" <<'CPP'
#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <map>
#include <sstream>
#include <cmath>
int main() {
  std::vector<std::string> v{"b", "a"};
  std::sort(v.begin(), v.end());
  std::map<std::string, int> m;
  m[v[0]] = 1;
  std::ostringstream os;
  os << v[0] << m.size() << std::sqrt(16.0);
  std::cout << os.str() << "\n";
}
CPP

cat > "$WORK/plain.cpp" <<'CPP'
int main() { return 0; }
CPP

cat > "$WORK/bad.cpp" <<'CPP'
#include <iostream>
int main() { std::cout << no_such_identifier << "\n"; return 0; }
CPP

# Same flags, limits and PATH the worker passes for a compile. `-H` is added
# only by this check: GCC marks a precompiled header it consumed with a leading
# '!', which is the whole oracle for "did the PCH actually get used".
ENVARGS="-E HOME=/tmp -E PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# $1 label, $2 include path or "" for none, rest: extra compiler flags.
# Result in $USED, $EXITCODE, $STATUS, $OUTPUT.
compile() {
  label=$1
  include=$2
  shift 2
  rm -f "$WORK/meta.txt" "$BOXDIR/out.bin"
  OUTPUT=$(isolate -b "$BOX" -s -M "$WORK/meta.txt" --stderr-to-stdout -i /dev/null \
    $ENVARGS -t 20 -x 0 -w 20 -k 64000 -p60 -m 512000 -f 4096 \
    --run -- "$CXX" -O0 -pipe $include "$@" -H -o out.bin main.cpp 2>&1)
  EXITCODE=$(sed -n 's/^exitcode://p' "$WORK/meta.txt")
  STATUS=$(sed -n 's/^status://p' "$WORK/meta.txt")
  USED=header
  if printf '%s\n' "$OUTPUT" | grep -q "^! $PCHDIR/iostream.gch$"; then
    USED=pch
  fi
  printf '   [%s] used=%s exitcode=%s status=%s\n' \
    "$label" "$USED" "${EXITCODE:-?}" "${STATUS:-ok}"
}

expect_compile() { # description, wanted used, wanted exitcode
  expect "$1 consumed by GCC" "$2" "$USED"
  expect "$1 compiler exit status" "$3" "$EXITCODE"
  if [ "$3" = "0" ]; then
    expect "$1 has no sandbox failure" "" "$STATUS"
  fi
}

cp "$WORK/io.cpp" "$BOXDIR/main.cpp"
compile "iostream" "-I$PCHDIR"
expect_compile "a normal iostream program" pch 0

cp "$WORK/many.cpp" "$BOXDIR/main.cpp"
compile "several headers" "-I$PCHDIR"
expect_compile "a program with several standard headers" pch 0

cp "$WORK/plain.cpp" "$BOXDIR/main.cpp"
compile "no includes" "-I$PCHDIR"
expect_compile "a program that includes nothing" header 0

cp "$WORK/bad.cpp" "$BOXDIR/main.cpp"
compile "student error" "-I$PCHDIR"
if [ "${EXITCODE:-0}" != "0" ] && printf '%s\n' "$OUTPUT" | grep -q "no_such_identifier"; then
  ok "a student compile error is still reported, with the student's own diagnostic"
else
  bad "a student compile error was not reported as one"
fi

# A student's compiler_options can invalidate the PCH. GCC then parses the
# headers the normal way, so the submission still compiles -- and no warning
# about the PCH is allowed to leak into what the student sees.
cp "$WORK/io.cpp" "$BOXDIR/main.cpp"
compile "student -O2" "-I$PCHDIR" -O2
expect_compile "a program built with a student's -O2" header 0
if printf '%s\n' "$OUTPUT" | grep -qi "invalid\|not used"; then
  bad "a fallback PCH leaked a warning into the student's compile output"
else
  ok "a fallback PCH says nothing in the student's compile output"
fi

compile "student -std=c++11" "-I$PCHDIR" -std=c++11
expect_compile "a program built with a student's -std=c++11" header 0

# The PCH directory as it is when the image ships without one: the same argv the
# worker builds, minus the include path.
cp "$WORK/io.cpp" "$BOXDIR/main.cpp"
compile "no PCH installed" ""
expect_compile "a program compiled with no PCH present" header 0

# A PCH built for a different language, which GCC ignores. It has a correct
# manifest, so the gate offers it: the point is that a *usable-looking* wrong
# PCH is harmless rather than fatal.
mkdir -p "$BOXDIR/wrong"
"$CXX" -x c-header /usr/include/stdio.h -o "$BOXDIR/wrong/iostream.gch" 2>/dev/null
if [ -s "$BOXDIR/wrong/iostream.gch" ]; then
  cp "$WORK/io.cpp" "$BOXDIR/main.cpp"
  compile "wrong-language PCH" "-Iwrong"
  expect_compile "a PCH built for C instead of C++" header 0
else
  bad "the image could not build a C-language PCH to test against"
fi

# ---------------------------------------------------------------------------
# 3. The result is a native ARM64 program, and it runs.
# ---------------------------------------------------------------------------
cp "$WORK/io.cpp" "$BOXDIR/main.cpp"
compile "final binary" "-I$PCHDIR"
expect_compile "the program the code below runs" pch 0

# e_machine at offset 18 of the ELF header: b7 00 is EM_AARCH64 on a
# little-endian host. This is what replaces `file`, which the image does not ship.
expected_machine=" b7 00"
actual_machine=$(od -An -tx1 -j18 -N2 "$BOXDIR/out.bin" 2>/dev/null)
expect "the PCH-built executable is an ARM64 ELF" "$expected_machine" "$actual_machine"

expect "the compiler targets aarch64" "aarch64-linux-gnu" "$("$CXX" -dumpmachine)"

rm -f "$WORK/run-meta.txt"
RUN_OUTPUT=$(isolate -b "$BOX" -s -M "$WORK/run-meta.txt" --stderr-to-stdout -i /dev/null \
  $ENVARGS -t 10 -x 0 -w 20 -k 64000 -p60 -m 512000 -f 4096 --run -- ./out.bin 2>&1)
expect "the PCH-built executable runs and prints its output" "hi" "$RUN_OUTPUT"
expect "the run reports no sandbox failure" "" "$(sed -n 's/^status://p' "$WORK/run-meta.txt")"

if [ "$failures" -eq 0 ]; then
  printf '\nall precompiled-header container checks passed\n'
else
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
