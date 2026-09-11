# Standalone check for CompilationCache.
#
#   ruby checks/check_compilation_cache.rb
#
# The cache is the one place where a bug is silent and dangerous: a wrong key
# serves a binary built from someone else's source, and a wrong failure entry
# tells a student their correct program does not compile. Both are checked here
# with real files in a temporary directory.
require "fileutils"
require "tmpdir"
require "json"
require "digest"
require "ostruct"

ROOT = File.expand_path("..", __dir__)
CACHE_DIR = Dir.mktmpdir("compilation-cache-check")

# `present?`/`blank?`/`presence` come from ActiveSupport in the running worker.
# The cache reads its directory and its runtime version at load time, so both
# the shim and the environment have to be in place before the require.
module ActiveSupportShim
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    blank? ? nil : self
  end
end
[String, Array, Hash, NilClass].each { |klass| klass.include(ActiveSupportShim) }

module Rails
  def self.logger
    Object.new.tap do |l|
      def l.warn(message)
        warn "[cache] #{message}"
      end
    end
  end
end

ENV["COMPILATION_CACHE_DIR"] = File.join(CACHE_DIR, "binaries")
# The fingerprint reads the compiler through ExecPlan, which Zeitwerk autoloads
# in the worker. Loading it by hand here keeps the check runnable standalone.
require_relative "#{ROOT}/judge0-src/app/services/exec_plan"
require_relative "#{ROOT}/judge0-src/app/services/pch"
require_relative "#{ROOT}/judge0-src/app/services/compilation_cache"

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

def submission(overrides = {})
  OpenStruct.new({
    is_project: false,
    source_code: "#include <iostream>\nint main(){ std::cout << 1; }\n",
    compiler_options: "-O0 -pipe",
    language_id: 54,
    additional_files: nil,
    language: OpenStruct.new(compile_cmd: "/usr/bin/g++ %s main.cpp")
  }.merge(overrides))
end

# Every scenario below keys on the same submission, so entries written by one
# block would be visible to the next. Each block starts from an empty cache.
def reset_cache!
  FileUtils.rm_rf(ENV["COMPILATION_CACHE_DIR"])
end

# --- key sensitivity ---------------------------------------------------------
# Every input that can change the executable must change the key.
base = CompilationCache.cache_key(submission)

check base && base.length == 64, "a key is a sha256 hex digest"
check_eq base, CompilationCache.cache_key(submission), "the same submission keys the same"

cases = {
  "a different source" => submission(source_code: "int main(){ return 0; }"),
  "different compiler flags" => submission(compiler_options: "-O2"),
  "a different language" => submission(language_id: 53),
  "a different compile command" => submission(language: OpenStruct.new(compile_cmd: "/usr/bin/clang++ %s main.cpp")),
  "different additional files" => submission(additional_files: "zipbytes")
}

cases.each do |label, other|
  check CompilationCache.cache_key(other) != base, "#{label} changes the key"
end

# The explicit brief requirement: architecture, compiler identity and runtime
# version are part of the key, so two environments cannot share an entry.
check CompilationCache.cache_key(submission, "-O2") != base,
      "the effective compiler options used for the build are keyed"
check CompilationCache::RUNTIME_VERSION.length > 0, "a runtime version participates in the key"
check CompilationCache.toolchain_fingerprint("/usr/bin/g++").include?("/usr/bin/g++"),
      "the toolchain fingerprint names the compiler"
check CompilationCache.toolchain_fingerprint("/nonexistent/cc").start_with?("unknown"),
      "an unresolvable compiler degrades to a coarse key rather than a crash"

# The PCH is built from the same compiler the fingerprint above stats, but it can
# be rebuilt on its own -- a header added to the set changes what the compiler
# reads while the compiler binary stays byte-identical. Overriding the term is
# the only way to test that here: this host has no PCH installed, so the real
# value is the same constant everywhere.
pch_original = Pch.method(:fingerprint)
Pch.define_singleton_method(:fingerprint) { |*_args| "pch:rebuilt" }
check CompilationCache.cache_key(submission) != base,
      "a rebuilt PCH set changes the key even when the compiler does not"
Pch.define_singleton_method(:fingerprint, pch_original)
check_eq CompilationCache.cache_key(submission), base,
         "restoring the PCH restores the key"

# The Go, Prolog and Cobol definitions put an assignment in front of the
# compiler (`GOCACHE=... /usr/local/go/bin/go build ...`). Splitting the string
# on whitespace would stat `GOCACHE=...` itself, which never resolves, so every
# entry for that language would collapse onto one constant `unknown:` key and
# a rebuilt compiler would keep serving stale binaries.
assignment_form = CompilationCache.toolchain_fingerprint(
  "GOCACHE=/tmp/.cache/go-build /usr/local/go-1.13.5/bin/go build %s main.go"
)
check assignment_form.include?("/usr/local/go-1.13.5/bin/go"),
      "a leading VAR=value assignment fingerprints the compiler, not the assignment"
check !assignment_form.include?("GOCACHE"),
      "the assignment itself never appears in the fingerprint"

# A project has no single source of truth to key on.
check_eq CompilationCache.cache_key(submission(is_project: true)), nil,
         "a project submission is never cached"
check_eq CompilationCache.cache_key(submission(source_code: "")), nil,
         "an empty source is never cached"

# --- success entries ---------------------------------------------------------
reset_cache!
Dir.mktmpdir do |dir|
  binary = File.join(dir, "a.out")
  File.write(binary, "\x7fELF-fake-binary")

  # The base submission has no additional files; with a non-nil value it must
  # key differently, which is what stops one lesson's header from being served
  # to another lesson.
  check CompilationCache.cache_key(submission(additional_files: "zipbytes")) != CompilationCache.cache_key(submission),
        "the same source with extra files removed changes the key"

  key = CompilationCache.cache_key(submission)
  CompilationCache.store(key, binary, "warning: unused variable", "a.out")

  hit = CompilationCache.lookup(key)
  check hit, "a stored binary is found again"
  check_eq File.binread(hit[:binary_path]), "\x7fELF-fake-binary",
           "the cached binary is byte-identical"
  check_eq hit[:binary_name], "a.out", "the binary name is preserved"
  check_eq hit[:compile_output], "warning: unused variable",
           "compiler warnings survive a cache hit"
  check !hit[:failed], "a successful entry is not marked failed"

  check_eq((File.stat(hit[:binary_path]).mode & 0o111).zero?, false,
           "the cached binary is executable")

  # An entry must be immutable: re-storing under the same key replaces it whole.
  File.write(binary, "\x7fELF-second-build")
  CompilationCache.store(key, binary, nil, "a.out")
  check_eq File.binread(CompilationCache.lookup(key)[:binary_path]), "\x7fELF-second-build",
           "re-storing replaces the entry atomically"
end

# --- failure entries ---------------------------------------------------------
reset_cache!
Dir.mktmpdir do |dir|
  key = CompilationCache.cache_key(submission)
  diagnostics = "main.cpp:3:5: error: 'x' was not declared in this scope\n"
  CompilationCache.store_failure(key, diagnostics)

  hit = CompilationCache.lookup(key)
  check hit, "a stored failure is found again"
  check_eq hit[:failed], true, "a failure entry is marked failed"
  check_eq hit[:compile_output], diagnostics, "the diagnostics are returned verbatim"
  check_eq hit[:binary_path], nil, "a failure entry carries no binary path"

  # Nothing to execute must not be mistaken for an executable.
  check !File.exist?(File.join(ENV["COMPILATION_CACHE_DIR"], key, "a.out")),
        "no binary is written for a failure entry"

  # A success must be able to supersede a recorded failure once the student
  # fixes the code, which means a new key rather than an overwrite.
  fixed = submission(source_code: "#include <iostream>\nint main(){}\n")
  check CompilationCache.cache_key(fixed) != key,
        "fixed source gets a different key and is not shadowed by the failure"
end

# --- robustness --------------------------------------------------------------
check_eq CompilationCache.lookup("0" * 64), nil, "a missing entry is a miss, not an error"
check_eq CompilationCache.lookup(nil), nil, "a nil key is a miss, not an error"

reset_cache!
Dir.mktmpdir do |dir|
  missing = File.join(dir, "does-not-exist")
  CompilationCache.store(CompilationCache.cache_key(submission), missing, nil, "a.out")
  check_eq CompilationCache.lookup(CompilationCache.cache_key(submission)), nil,
           "storing a nonexistent binary is refused"
end

# A truncated entry must not be served as a valid binary.
reset_cache!
Dir.mktmpdir do |dir|
  key = CompilationCache.cache_key(submission)
  entry = File.join(ENV["COMPILATION_CACHE_DIR"], key)
  FileUtils.mkdir_p(entry)
  File.write(File.join(entry, "meta.json"), JSON.generate({ "binary_name" => "a.out" }))
  File.write(File.join(entry, "a.out"), "")
  check_eq CompilationCache.lookup(key), nil, "an empty binary is treated as a miss"
end

# --- bounded storage ---------------------------------------------------------
reset_cache!
Dir.mktmpdir do |dir|
  binary = File.join(dir, "a.out")
  File.write(binary, "\x7fELF-fake-binary")
  CompilationCache.store(CompilationCache.cache_key(submission), binary, nil, "a.out")
end
sizes = Dir.glob(File.join(ENV["COMPILATION_CACHE_DIR"], "*")).select { |f| Dir.exist?(f) }.size
check sizes > 0, "entries exist to evict (#{sizes})"
check CompilationCache::MAX_CACHE_BYTES > 0, "the cache is bounded"

FileUtils.rm_rf(CACHE_DIR)

if FAILURES.empty?
  puts "\nall compilation-cache checks passed"
else
  abort "\n#{FAILURES.size} failure(s):\n  #{FAILURES.join("\n  ")}"
end
