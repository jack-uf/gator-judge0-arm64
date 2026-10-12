redis_port = (ENV["REDIS_PORT"].presence || 6379).to_i

Resque.redis = Redis.new(
  host:     ENV["REDIS_HOST"],
  port:     redis_port,
  password: ENV["REDIS_PASSWORD"],
  thread_safe: true
)

if ENV["RESQUE_NAMESPACE"].present?
  Resque.redis.namespace = ENV["RESQUE_NAMESPACE"].to_sym
end

# Disable Resque per-job process fork overhead.
# Persistent workers process jobs directly in-process.
ENV["FORK_PER_JOB"] = "false"

# Override Resque::Worker#reserve to use Redis BLPOP instead of 100ms busy polling.
# This eliminates idle CPU usage and idle Redis queries, and enables instant wake-up.
module ResqueBlockingWorker
  def reserve(interval = 2.0)
    # Check if there's already a job waiting in any queue
    queues.each do |queue|
      if (job = Resque.reserve(queue))
        return job
      end
    end

    # Use BLPOP on all worker queues
    raw_redis = Resque.redis.redis
    ns = Resque.redis.namespace ? "#{Resque.redis.namespace}:" : ""
    redis_keys = queues.map { |q| "#{ns}queue:#{q}" }
    return nil if redis_keys.empty?

    timeout = [interval.to_i, 2].max
    res = raw_redis.blpop(*redis_keys, timeout: timeout)
    if res
      q_key, payload_json = res
      queue_name = q_key.sub(/\A.*queue:/, "")
      payload = Resque.decode(payload_json)
      return Resque::Job.new(queue_name, payload)
    end

    nil
  rescue Exception => e
    log_with_severity :error, "Error reserving job with BLPOP: #{e.inspect}"
    nil
  end
end

Resque::Worker.prepend(ResqueBlockingWorker)
