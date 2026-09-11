# Standalone check for the Isolate argv the worker builds.
#
# Runs with the system ruby and no Rails: the method bodies are re-evaluated
# from the shipped isolate_job.rb, so this fails if that source drifts.
#
#   ruby checks/check_sandbox_argv.rb
#
# The regressions guarded here are the ones the old `isolate ... > file` shell
# string used to hide:
#   * "-m 512000" must arrive as two argv tokens, not one token with a space.
#   * the empty cgroups string must not become an empty argument.
#   * LD_LIBRARY_PATH from the language definition must reach the program.
#   * argv order is load bearing: --run then -- then the program.
JOB_SOURCE = File.expand_path(
  "../judge0-src/app/jobs/isolate_job.rb", __dir__
).then { |p| abort("missing #{p}") unless File.exist?(p); File.read(p) }

# `present?` comes from ActiveSupport in the running worker; supply the same
# definition here so the extracted method bodies behave identically.
# `present?` comes from ActiveSupport in the running worker; supply the same
# definitions here so the extracted method bodies behave identically.
[String, Hash, Array].each do |klass|
  klass.class_eval do
    def present?
      !empty?
    end
  end
end
# String#strip is not empty-safe for the whitespace case, and Isolate treats an
# all-whitespace cgroups string as no cgroups at all.
class String
  def present?
    !strip.empty?
  end
end

class FakeSubmission
  attr_accessor :enable_per_process_and_thread_time_limit,
                :enable_per_process_and_thread_memory_limit,
                :compile_output
end

class FakeJob
  attr_accessor :submission, :cgroups, :box_id, :metadata_file

  def evaluate(name)
    body = JOB_SOURCE[/^  def #{name}\b.*?^  end$/m]
    abort "could not extract #{name} from isolate_job.rb" unless body
    instance_eval(body, "isolate_job.rb")
  end
end

def check(condition, message)
  abort("FAIL: #{message}") unless condition
  puts "ok: #{message}"
end

def check_eq(actual, expected, message)
  unless actual == expected
    abort("FAIL: #{message}\n  got:      #{actual.inspect}\n  expected: #{expected.inspect}")
  end
  puts "ok: #{message}"
end

job = FakeJob.new
job.box_id = 7
job.metadata_file = "/dev/shm/judge0/7/metadata.txt"
job.cgroups = ""
submission = FakeSubmission.new
submission.enable_per_process_and_thread_time_limit = false
submission.enable_per_process_and_thread_memory_limit = false
job.submission = submission

%w[memory_limit_args timing_flag isolate_env_args sandbox_argv
   base_argv cacheable_compile_failure?].each { |m| job.evaluate(m) }

# --- memory limits -----------------------------------------------------------
check_eq job.memory_limit_args(false, 512000), ["--cg-mem=512000"],
         "cgroup mode passes --cg-mem=N as a single token"

rss = job.memory_limit_args(true, 512000)
check_eq rss, ["-m", "512000"], "per-process mode passes -m and its value separately"
check(!rss.include?("-m 512000"), "no token carries an embedded space")

# --- timing flag -------------------------------------------------------------
job.cgroups = "--cg"
check job.timing_flag == "--cg-timing",
      "cgroups on: per-process time limit off keeps cgroup timing"

submission.enable_per_process_and_thread_time_limit = true
check_eq job.timing_flag, "--no-cg-timing",
         "per-process time limit turns cgroup timing off"

job.cgroups = ""
check_eq job.timing_flag, nil, "no cgroups means no timing flag at all"
job.cgroups = "--cg"

# --- sandbox_argv ------------------------------------------------------------
flags = ["-s", "--stderr-to-stdout", job.timing_flag,
         *job.memory_limit_args(false, 512000)]
args = job.sandbox_argv(flags, { argv: ["./a.out"], env: {} })

check(!args.include?(""), "an empty cgroups string never becomes an argument")
check_eq args.count("--cg-mem=512000"), 1, "memory flag present exactly once"
check_eq args.first, "isolate", "argv starts with the isolate binary"
check_eq args[args.index("-b") + 1], "7", "-b carries the box id"
check_eq args.last, "./a.out", "the program argv is last"

run_at = args.index("--run")
sep_at = args.index("--")
check run_at && sep_at && run_at < sep_at, "--run precedes the argv separator"
check_eq args[sep_at + 1, 1], ["./a.out"], "separator is immediately followed by argv"

# --- language env ------------------------------------------------------------
env_args = job.sandbox_argv(
  [],
  { argv: ["./a.out"], env: {} },
  plan_env: { "LD_LIBRARY_PATH" => "/usr/local/gcc-9.2.0/lib64" }
)
at = env_args.index("LD_LIBRARY_PATH=/usr/local/gcc-9.2.0/lib64")
check at, "LD_LIBRARY_PATH is passed through as -E KEY=value"
check_eq env_args[at - 1], "-E", "the env assignment is preceded by -E"
check at < env_args.index("--run"), "language env is set before the run"

check env_args.include?("HOME=/tmp"), "HOME=/tmp preserved"
check env_args.include?("/etc:noexec"), "-d /etc:noexec preserved"

# --- lifecycle invocations ---------------------------------------------------
# --init and --cleanup are lifecycle calls, not executions: they take no
# program, so they must stop at the flag prefix. Sending them through
# sandbox_argv would append `--run --` and Isolate would look for a program.
init_args = job.base_argv(["-b", "7", "--init"])
check_eq init_args, ["isolate", "--cg", "-b", "7", "--init"],
         "--init is the isolate binary, the cgroup mode, and its own flags"
check !init_args.include?("--run"), "--init never carries --run"
check !init_args.include?("--"), "--init never carries the argv separator"

job.cgroups = ""
check_eq job.base_argv(["-b", "7", "--cleanup"]), ["isolate", "-b", "7", "--cleanup"],
         "with no cgroups the lifecycle argv is just the binary and flags"
check !job.base_argv(["-b", "7", "--cleanup"]).include?(""),
      "an empty cgroups string never becomes an argument"
job.cgroups = "--cg"

# --- compile failure classification ------------------------------------------
# Only a genuine compiler error may be recorded against the source. A sandbox
# fault ("XX") or an exhausted compile allowance ("TO") is a property of the
# attempt, so caching either would make a transient fault permanent for that
# student. The regression guarded here is the one that looks safe in a diff.
submission.compile_output = "main.cpp:1:1: error: nope"
check job.cacheable_compile_failure?("RE"), "a real compiler error is cacheable"
check !job.cacheable_compile_failure?("TO"), "a compile timeout is never cached"
check !job.cacheable_compile_failure?("XX"), "a sandbox fault is never cached"
check !job.cacheable_compile_failure?(nil), "a missing status is never cached"

submission.compile_output = ""
check !job.cacheable_compile_failure?("RE"),
      "an error with no diagnostics is not cached (nothing to replay)"

submission.compile_output = "main.cpp:1:1: error: nope"
check !job.cacheable_compile_failure?("SG"),
      "a program killed by a signal is not cached"

puts "\nall sandbox_argv checks passed"
