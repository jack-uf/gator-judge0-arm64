module Judge0Redis
  # Completion events are one list per submission. The execution worker pushes a
  # marker the moment the final state is durable; a synchronous (wait=true)
  # request blocks on the same list instead of polling PostgreSQL.
  #
  # Two properties matter here and both are load bearing:
  #
  #   * The push must never block on a reader. It is a plain RPUSH, so the
  #     worker cannot stall behind a request that is already gone.
  #   * A reader must never destroy an event it did not consume. The list is
  #     written once per run, so a submission evaluated against several tests
  #     pushes several markers into the same list.
  DONE = "done".freeze

  # Long enough that a reader arriving after a slow request cannot miss the
  # marker; short enough that abandoned submissions do not accumulate keys.
  EVENT_TTL_S = 300

  # redis-rb applies the client socket timeout to blocking commands, so a BLPOP
  # waiting minutes on a client configured for seconds raises Redis::TimeoutError
  # and is indistinguishable from a lost event. Blocking readers get their own
  # connection sized for the longest wait we ever ask for.
  MAX_BLOCKING_WAIT_S = 600
  SOCKET_MARGIN_S = 5

  def self.client
    Thread.current[:judge0_raw_redis] ||= Redis.new(
      host: ENV["REDIS_HOST"],
      port: ENV["REDIS_PORT"],
      password: ENV["REDIS_PASSWORD"],
      timeout: 30
    )
  end

  def self.blocking_client
    Thread.current[:judge0_blocking_redis] ||= Redis.new(
      host: ENV["REDIS_HOST"],
      port: ENV["REDIS_PORT"],
      password: ENV["REDIS_PASSWORD"],
      timeout: MAX_BLOCKING_WAIT_S + SOCKET_MARGIN_S
    )
  end

  def self.event_key(token)
    "judge0:submission:#{token}:done"
  end

  def self.notify_done(token)
    return unless token
    key = event_key(token)
    r = client
    r.rpush(key, DONE)
    r.expire(key, EVENT_TTL_S)
  rescue Exception => e
    Rails.logger.error("Judge0Redis.notify_done error for #{token}: #{e.message}")
  end

  def self.wait_done(token, timeout)
    return if token.blank? || timeout.to_f <= 0
    key = event_key(token)
    client_for_wait = blocking_client
    result = client_for_wait.blpop(key, timeout: timeout.to_f.ceil)
    # Only reclaim the key once every marker in it has been consumed. Deleting
    # unconditionally would drop the completion event of a later run in a
    # multi-test submission.
    client_for_wait.del(key) if result && client_for_wait.llen(key).to_i.zero?
    result
  rescue Exception => e
    Rails.logger.warn("Judge0Redis.wait_done error for #{token}: #{e.message}")
    nil
  end
end
