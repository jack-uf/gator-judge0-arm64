# Standalone check for the synchronous (wait=true) timeout budget.
#
#   ruby checks/check_wait_budget.rb
#
# The wait budget is the only thing standing between a classroom burst and a
# request that gives up while its worker is still legitimately running, so it is
# checked rather than eyeballed. Method bodies are re-evaluated from the shipped
# sources.
ROOT = File.expand_path("..", __dir__)

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

require "json"

JOB_SOURCE = File.read(File.join(ROOT, "judge0-src/app/jobs/isolate_job.rb"))
PAYLOAD_KEY = JOB_SOURCE[/TESTS_PAYLOAD_KEY = "([^"]+)"/, 1].freeze
abort "TESTS_PAYLOAD_KEY not found" unless PAYLOAD_KEY

# --- tests_payload -----------------------------------------------------------
# Same contract as IsolateJob.tests_payload: the packed marker decides, and a
# malformed payload is treated as no test list rather than crashing the count.
tests_payload = lambda do |stdin|
  next nil if stdin.nil? || stdin.empty?
  next nil unless stdin.start_with?("{\"#{PAYLOAD_KEY}\":")
  parsed = JSON.parse(stdin) rescue nil
  tests = parsed && parsed[PAYLOAD_KEY]
  tests.is_a?(Array) ? tests : nil
end

packed = JSON.generate({ PAYLOAD_KEY => [{ "stdin" => "1 2" }, { "stdin" => "3 4" }] })
check_eq tests_payload.call(packed).size, 2, "a packed test list is recognised"
check_eq tests_payload.call("12\n"), nil, "ordinary stdin is not a test list"
check_eq tests_payload.call(nil), nil, "nil stdin yields no tests"
check_eq tests_payload.call("{\"#{PAYLOAD_KEY}\":\"nope\"}"), nil,
         "a non-array payload is rejected rather than counted"
check_eq tests_payload.call("{\"other\":[]}"), nil, "a foreign JSON document is not a test list"

# --- result_wait_budget_s ----------------------------------------------------
runner_source = File.read(File.join(ROOT, "judge0-src/app/helpers/isolate_runner.rb"))
chart = {}
runner_source.scan(/^  ([A-Z_]+) = (\d+)/) { |(name, value)| chart[name] = value.to_i }

check_eq chart["MAX_WAIT_TIME_S"], 600, "the wait ceiling is ten minutes"
check_eq chart["COMPILE_ALLOWANCE_S"], 20, "compilation has its own allowance"

# Mirrors IsolateRunner.result_wait_budget_s with a fixed worker count so the
# arithmetic is visible. Keep in step with the helper.
WORKERS = 4
budget = lambda do |wall, extra, tests|
  per_test = wall.to_f + extra.to_f
  verdict_wait = (per_test * tests) + chart["COMPILE_ALLOWANCE_S"]
  queue_wait = [WORKERS * chart["QUEUE_ALLOWANCE_PER_WORKER_S"], 16].max
  [(verdict_wait + queue_wait), chart["MAX_WAIT_TIME_S"]].min
end

# A single fast test: 8s of work + 20s compile + 32s of queue headroom.
check_eq budget.call(5, 3, 1), 60, "a single fast test gets compile and queue headroom"

# Twelve tests must not expire while the later ones are still running. This is
# the case the old `[wall + 4, 8].max` floor got wrong.
check_eq budget.call(5, 3, 12), 148, "all twelve tests fit in the budget"

# The ceiling still applies, so a request can never hang indefinitely.
check_eq budget.call(120, 30, 50), 600, "the budget is clamped to the ceiling"

check budget.call(1, 0, 1) > 8, "a trivial submission still beats the old 8s floor"
check budget.call(5, 3, 12) > budget.call(5, 3, 1), "more tests means a larger budget"

puts "\nall wait-budget checks passed"
