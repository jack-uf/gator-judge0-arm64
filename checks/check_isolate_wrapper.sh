#!/bin/sh
# Runs the shipped isolate wrapper with a stub in place of the real Isolate and
# prints the argv Isolate would have received.
#
#   sh checks/check_isolate_wrapper.sh
#
# The wrapper rewrites cgroup flags into rlimits and rotates "$@" to do it. If
# that rotation drops or merges an argument, Isolate silently receives a
# different command than the worker built, which is exactly the class of bug
# that produced `-m 512000` as one argument.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/isolate.bin" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '[%s]\n' "$a"; done
STUB
chmod +x "$WORK/isolate.bin"

sed "s|/usr/local/bin/isolate.bin|$WORK/isolate.bin|" \
  "$ROOT/isolate-wrapper.sh" > "$WORK/wrapper"
chmod +x "$WORK/wrapper"

failures=0

expect() {
  description=$1
  expected=$2
  shift 2

  # Every POSIX shell the image could have as /bin/sh, not just the one this
  # host happens to use. bash and dash disagree about ${#} arithmetic on some
  # inputs, and the worker's /bin/sh is dash.
  for shell in sh dash bash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    actual=$("$shell" "$WORK/wrapper" "$@" | tr '\n' ' ')
    if [ "$actual" = "$expected" ]; then
      printf 'ok: %s (%s)\n' "$description" "$shell"
    else
      failures=$((failures + 1))
      printf 'FAIL: %s (%s)\n  expected: %s\n  got:      %s\n' \
        "$description" "$shell" "$expected" "$actual"
    fi
  done
}

# The rewrite that the whole wrapper exists for: Isolate does its own getopt and
# splits nothing, so the flag and its value must stay two arguments.
expect "cgroup memory flag becomes -m and its value" \
  "[-m] [512000] [-b] [7] [--init] " \
  --cg --cg-mem=512000 -b 7 --init

# The cgroup-only flags have no meaning here and Isolate rejects them.
expect "cgroup flags are dropped" \
  "[-m] [512000] [-b] [7] [--run] [--] [./a.out] " \
  --cg --cg-mem=512000 --cg-timing -b 7 --run -- ./a.out

expect "per-process flags pass through untouched" \
  "[-m] [2048] [-b] [7] [--cleanup] " \
  -m 2048 --no-cg-timing -b 7 --cleanup

# Argument boundaries survive: a value containing a space must stay one
# argument. A wrapper that built a string and re-split it would fail here.
expect "a value containing a space stays one argument" \
  "[-E] [LD_LIBRARY_PATH=/opt/my lib] [-b] [3] [--run] [--] [./a.out] " \
  -E "LD_LIBRARY_PATH=/opt/my lib" -b 3 --run -- ./a.out

expect "a value containing quotes stays intact" \
  "[-E] [X=it's \"quoted\"] [-b] [3] [--init] " \
  -E 'X=it'"'"'s "quoted"' -b 3 --init

# An empty argument is meaningful to Isolate (it is how a variable is cleared),
# so the rotation must not swallow it.
expect "an empty argument is preserved, not dropped" \
  "[-E] [] [-b] [7] [--init] " \
  -E "" -b 7 --init

# Rotation must not confuse an option's value with another option.
expect "an argument that looks like a flag is preserved in position" \
  "[-E] [-b] [--] [-b] " \
  -E -b -- -b

expect "an argument list that is only cgroup flags reaches the binary empty" \
  "" \
  --cg --cg-timing

if [ "$failures" -eq 0 ]; then
  printf '\nall isolate-wrapper checks passed\n'
else
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
