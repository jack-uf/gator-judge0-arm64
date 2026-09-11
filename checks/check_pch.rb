# Standalone check for the precompiled-header gate.
#
#   ruby checks/check_pch.rb
#
# The PCH only makes compiles faster when it is intact, and it actively breaks
# them when it is damaged: GCC treats a truncated `.gch` as a hard error, which
# the worker would report to the student as if their program were wrong. So the
# whole optimisation hangs on one question -- does the worker offer the PCH only
# when the file on disk is bit-for-bit the file the image built? -- and that is
# what this check answers, with real files in temporary directories.
#
# The container-side sibling, `checks/check_pch.sh`, proves the same gate keeps
# working through a real Isolate compile and that the image's PCH is the one it
# claims to be.
require "digest"
require "fileutils"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
# Both are Zeitwerk-autoloaded in the worker and have no Rails dependency, so
# the check can load them by hand and stay runnable outside the app.
require_relative "#{ROOT}/judge0-src/app/services/exec_plan"
require_relative "#{ROOT}/judge0-src/app/services/pch"

DOCKERFILE = File.join(ROOT, "Dockerfile.arm64")

FAILURES = []

def check(condition, message)
  if condition
    puts "ok: #{message}"
  else
    FAILURES << message
    puts "FAIL: #{message}"
  end
end

def check_eq(actual, expected, message)
  if actual == expected
    puts "ok: #{message}"
  else
    FAILURES << message
    puts "FAIL: #{message}\n  got:      #{actual.inspect}\n  expected: #{expected.inspect}"
  end
end

# A directory shaped exactly like the one the image installs: one of more `.gch`
# files plus a manifest that names their contents. `body` is the file content,
# so a caller can replace it to model a damaged or foreign PCH.
def pch_dir(dir, body: "gpch-fake-precompiled-header", file: "iostream.gch", manifest: nil)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, file), body)
  manifest ||= "#{Digest::SHA256.hexdigest(body)}  #{file}\n"
  File.write(File.join(dir, Pch::MANIFEST), manifest)
  dir
end

Dir.mktmpdir("pch-check") do |tmp|
  # --- the happy path -------------------------------------------------------
  good = pch_dir(File.join(tmp, "good"))
  check Pch.usable?(good), "a manifest matching the file on disk is accepted"
  check_eq Pch.include_args(good), ["-I#{good}"],
           "an accepted PCH is offered as an include path"
  check Pch.fingerprint(good).match?(/\Apch:[0-9a-f]{64}\z/),
        "an accepted PCH has a content-derived fingerprint"

  # --- nothing installed ----------------------------------------------------
  bare = File.join(tmp, "bare")
  FileUtils.mkdir_p(bare)
  File.write(File.join(bare, "iostream.gch"), "gpch-fake-precompiled-header")
  check !Pch.usable?(bare), "a PCH with no manifest is refused"
  check_eq Pch.include_args(bare), [], "a PCH with no manifest adds no flag"
  check_eq Pch.fingerprint(bare), "pch:none",
           "the absence of a PCH is its own cache key term"

  missing_dir = File.join(tmp, "absent")
  check !Pch.usable?(missing_dir), "a directory that does not exist is refused"
  check_eq Pch.include_args(missing_dir), [], "an absent directory adds no flag"

  # --- damaged files --------------------------------------------------------
  # Truncation is the case that must never be passed on: GCC fails the compile
  # outright and the diagnostics would be attributed to the student's source.
  cut = File.join(tmp, "cut")
  pch_dir(cut, body: "gpch-fake-precompiled-header")
  File.truncate(File.join(cut, "iostream.gch"), 8)
  check !Pch.usable?(cut), "a truncated PCH is refused"
  check_eq Pch.include_args(cut), [], "a truncated PCH adds no flag"

  empty = File.join(tmp, "empty")
  pch_dir(empty)
  File.write(File.join(empty, "iostream.gch"), "")
  check !Pch.usable?(empty), "an emptied PCH is refused"

  # A replacement of the same length is the case a size check would miss and
  # the case a stale PCH from another compiler produces.
  foreign = pch_dir(File.join(tmp, "foreign"))
  original_size = File.size(File.join(foreign, "iostream.gch"))
  File.write(File.join(foreign, "iostream.gch"), "g" + "p" * (original_size - 1))
  check !Pch.usable?(foreign),
        "a same-length replacement (a PCH from another compiler) is refused"

  # --- damaged manifests ----------------------------------------------------
  nothing_listed = File.join(tmp, "nothing-listed")
  pch_dir(nothing_listed, manifest: "\n")
  check !Pch.usable?(nothing_listed), "an empty manifest is refused"

  unlisted = File.join(tmp, "unlisted")
  pch_dir(unlisted, manifest: "#{Digest::SHA256.hexdigest("x")}  iostream.gch\n")
  check !Pch.usable?(unlisted), "a manifest naming a file that is not there is refused"

  short_digest = File.join(tmp, "short-digest")
  pch_dir(short_digest, manifest: "deadbeef  iostream.gch\n")
  check !Pch.usable?(short_digest), "a manifest line that is not a sha256 is refused"

  traversal = File.join(tmp, "traversal")
  pch_dir(traversal, manifest: "#{Digest::SHA256.hexdigest("x")}  ../iostream.gch\n")
  check !Pch.usable?(traversal), "a manifest entry pointing outside the directory is refused"

  # `sha256sum --binary` marks the name with a leading '*'; the parser strips it
  # rather than rejecting the line, so a manifest generated that way still works.
  binary_mode = File.join(tmp, "binary-mode")
  pch_dir(binary_mode, manifest: "#{Digest::SHA256.hexdigest("gpch-fake-precompiled-header")} *iostream.gch\n")
  check Pch.usable?(binary_mode), "sha256sum's binary-mode marker is tolerated"

  # --- the identity the cache keys on ---------------------------------------
  # Same filename, different content: the cache must not treat them as one PCH.
  first = pch_dir(File.join(tmp, "first"), body: "gpch-first")
  second = pch_dir(File.join(tmp, "second"), body: "gpch-second")
  check Pch.fingerprint(first) != Pch.fingerprint(second),
        "two PCH sets with different content fingerprint differently"
  check Pch.fingerprint(first) != Pch.fingerprint(bare),
        "an installed PCH keys differently from no PCH at all"
end

# --- the flag survives the parser the sandbox is built from ------------------
# The include path is appended to the command string, so it has to survive
# ExecPlan's round-trip check; if it did not, C++ compiles would silently fall
# back to the generated-script path.
plan = ExecPlan.parse("/usr/local/gcc-9.2.0/bin/g++ -O0 -pipe -I#{Pch::DIR} main.cpp")
check plan, "the C++ compile command with the PCH include path still parses"
check_eq plan && plan[:argv], ["/usr/local/gcc-9.2.0/bin/g++", "-O0", "-pipe", "-I#{Pch::DIR}", "main.cpp"],
         "the include path reaches the sandbox argv as one argument, in order"
check_eq plan && plan[:env], {}, "the include path does not turn into an env assignment"

# --- the shipped recipe and this code agree ---------------------------------
# The Dockerfile writes the manifest the gate reads and builds the file the
# manifest describes. Neither can be checked from Ruby at runtime, so the two
# constants are matched against the recipe that has to produce them.
dockerfile = File.read(DOCKERFILE)
check dockerfile.include?("mkdir -p #{Pch::DIR}"),
      "the image builds its PCH into the directory the gate reads (#{Pch::DIR})"
check dockerfile.include?("#{Pch::MANIFEST}"),
      "the image writes the manifest the gate reads (#{Pch::MANIFEST})"
check dockerfile.include?("-O0 -pipe -x c++-header"),
      "the PCH is built with the same flags the C++ compile path uses"
check dockerfile.include?("^! #{Pch::DIR}/iostream.gch$"),
      "the image refuses to build unless a compile consumes the PCH"

if FAILURES.empty?
  puts "\nall precompiled-header checks passed"
else
  abort "\n#{FAILURES.size} failure(s):\n  #{FAILURES.join("\n  ")}"
end
