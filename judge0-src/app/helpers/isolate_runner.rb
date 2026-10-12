module IsolateRunner
  MAX_WAIT_TIME_S = 600

  INITIAL_WAIT_TIME_S = 2
  NEXT_WAIT_TIME_S = 1
  WAIT_TIME_FACTOR_S = 0.5

  WAITING_STATUSES = [Status.queue.id, Status.process.id, nil]

  # Compilation plus schema/extract allowance, before any test runs.
  COMPILE_ALLOWANCE_S = 20
  # Headroom for time spent queued behind other submissions. Scaled by the
  # worker count: each worker drains its own job, so a burst deeper than the
  # pool is a real wait and is bounded by MAX_WAIT_TIME_S below.
  QUEUE_ALLOWANCE_PER_WORKER_S = 8

  def self.result_wait_budget_s(submission)
    per_test = submission.wall_time_limit.to_f + submission.cpu_extra_time.to_f
    tests = submission.test_count
    verdict_wait = (per_test * tests) + COMPILE_ALLOWANCE_S
    queue_wait = [worker_count * QUEUE_ALLOWANCE_PER_WORKER_S, 16].max
    [verdict_wait + queue_wait, MAX_WAIT_TIME_S].min
  end

  def self.worker_count
    count = ENV["COUNT"].presence.to_i
    count.positive? ? count : 1
  end

  def self.perform_now(submission)
    IsolateRunner.perform_later(submission)

    token = submission.token
    # The wall clock the job may consume is (tests x per-test wall limit) plus
    # compilation, and the queue may be deep during a classroom burst. Budgeting
    # only one test's wall time makes the wait expire while the worker is still
    # legitimately busy, which the caller sees as a hang.
    timeout = IsolateRunner.result_wait_budget_s(submission)

    # Block until worker completes execution
    Judge0Redis.wait_done(token, timeout)

    # Fast check: if status is already resolved, return immediately
    current_status = Submission.where(id: submission.id).pluck(:status_id).first
    return unless WAITING_STATUSES.include?(current_status)

    # Graceful fallback in case of lost event
    total_wait = 0
    while total_wait < 10
      sleep(0.05)
      total_wait += 0.05
      status = Submission.where(id: submission.id).pluck(:status_id).first
      break unless WAITING_STATUSES.include?(status)
    end
  end

  def self.perform_later(submission)
    IsolateJob.perform_later(submission.id)
  end
end
