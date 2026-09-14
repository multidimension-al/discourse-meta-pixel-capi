# frozen_string_literal: true

module DiscourseMetaPixel
  # A shared backoff, honoured by every flush at once.
  #
  # Sidekiq's own retry backoff is per job. When Meta rate limits a busy site
  # that is not enough: the flush that got the 429 waits, and every other flush
  # in the queue carries on hitting the same limit, which is how a rate limit
  # turns into a sustained one.
  #
  # So the deadline lives in Redis, where every worker sees it. One 429 stands
  # the whole plugin down until Meta's own `Retry-After` has passed.
  #
  # The buffer keeps filling meanwhile. That is intended: events are held, not
  # dropped, and the wait is bounded well inside Meta's deduplication window.
  module Throttle
    module_function

    KEY = "meta_pixel_capi_throttled_until"

    # Used when Meta rate limits without saying for how long.
    DEFAULT_BACKOFF = 60

    # A ceiling, so a malformed or hostile `Retry-After` cannot stand delivery
    # down for longer than the deduplication window tolerates.
    MAX_BACKOFF = 1.hour.to_i

    def throttled?
      remaining.positive?
    end

    # Seconds until delivery may resume, or 0 when it may resume now.
    def remaining
      until_at = Discourse.redis.get(KEY).to_i
      [until_at - Time.now.to_i, 0].max
    rescue ::Redis::BaseError
      0
    end

    # Stand delivery down for `seconds`, or until an existing longer deadline.
    def back_off!(seconds)
      seconds = seconds.to_i
      seconds = DEFAULT_BACKOFF unless seconds.positive?
      seconds = [seconds, MAX_BACKOFF].min

      deadline = Time.now.to_i + seconds
      current = Discourse.redis.get(KEY).to_i

      # Never shorten a standing deadline: two workers hitting the same limit
      # should extend the wait, not race to cut it short.
      return current if current >= deadline

      Discourse.redis.setex(KEY, seconds, deadline)
      deadline
    rescue ::Redis::BaseError
      nil
    end

    def clear
      Discourse.redis.del(KEY)
    rescue ::Redis::BaseError
      nil
    end
  end
end
