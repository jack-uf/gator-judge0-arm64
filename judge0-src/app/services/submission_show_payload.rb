module SubmissionShowPayload
  # Bumped whenever the shape of SubmissionSerializer's output changes: an
  # entry written by an older release must never satisfy a newer request.
  # v1 is the upstream cache, which keyed entries on the bare token.
  VERSION = 2

  # Statuses whose next read is the read the caller is waiting for. These are
  # never served from cache, because a one second TTL is indistinguishable from
  # "the worker has not finished yet" to whoever asked.
  UNCACHEABLE_STATUS_IDS = [Status.queue.id, Status.process.id].freeze

  def self.key(token)
    "submission:show:v#{VERSION}:#{token}"
  end

  def self.upstream_key(token)
    token.to_s
  end

  def self.invalidate(token)
    return if token.blank?
    Rails.cache.delete(key(token))
    # Upstream cached under the bare token. Deleting it keeps a rolled back
    # deployment from resurrecting a row that has since changed.
    Rails.cache.delete(upstream_key(token))
  rescue StandardError => e
    Rails.logger.warn("SubmissionShowPayload.invalidate(#{token}) failed: #{e.class}: #{e.message}")
  end

  def self.cacheable?(submission)
    !UNCACHEABLE_STATUS_IDS.include?(submission.status_id) && submission.status_id.present?
  end

  def self.read(token, submission)
    return submission unless cacheable?(submission)

    # Plain read, not fetch: every write to the row invalidates this entry, so a
    # miss means the worker is mid-flight and the fresh row is already the
    # freshest answer. Caching it here would race the invalidation.
    payload = Rails.cache.read(key(token))
    if payload.is_a?(Submission)
      payload
    else
      submission
    end
  end

  def self.write(token, submission, expires_in)
    return unless cacheable?(submission)

    Rails.cache.write(key(token), submission, expires_in: expires_in)
  rescue StandardError => e
    Rails.logger.warn("SubmissionShowPayload.write(#{token}) failed: #{e.class}: #{e.message}")
  end
end
