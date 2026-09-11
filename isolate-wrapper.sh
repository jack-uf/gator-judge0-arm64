#!/bin/sh
# Isolate wrapper for ARM64, which has no working cgroup delegation: the
# cgroup-only flags are rewritten into their rlimit equivalents so every
# submission still gets a real memory cap.
#
# /bin/sh rather than bash. This script is exec'd once per Isolate call -- three
# times per submission (--init, compile, --cleanup) -- so the interpreter it
# starts is pure fixed cost. dash, which is what /bin/sh is on Debian and
# Ubuntu, starts in a fraction of bash's time, and nothing here needs bash: the
# rewrite is the `case` plus prefix-strip form POSIX has always had.
#
# Each argument is rotated off the front and appended back only if it is kept.
# That is how a POSIX shell filters "$@" without arrays, and without building a
# string -- a string would lose the boundaries between arguments, and
# re-splitting it would re-interpret what they contain.
remaining=$#
while [ "$remaining" -gt 0 ]; do
  arg="$1"
  shift
  case "$arg" in
    --cg|--cg-timing|--no-cg-timing)
      # No cgroup support here, and Isolate rejects the flags outright.
      ;;
    --cg-mem=*)
      # `-m` and its value must be two arguments: Isolate does its own getopt
      # and splits nothing, so one "-m 512000" argument would be read as the
      # flag `-m` with an empty variable name.
      set -- "$@" -m "${arg#--cg-mem=}"
      ;;
    *)
      set -- "$@" "$arg"
      ;;
  esac
  remaining=$((remaining - 1))
done

exec /usr/local/bin/isolate.bin "$@"
