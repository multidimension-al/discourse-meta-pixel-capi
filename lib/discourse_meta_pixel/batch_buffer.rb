# frozen_string_literal: true

module DiscourseMetaPixel
  # The pending-delivery buffer.
  #
  # ## Why this is in Redis rather than the deliveries table
  #
  # A browser-mirrored event carries transient matching data — IP address, user
  # agent, `_fbp`, `_fbc` — that deliberately never reaches Postgres. Batching
  # by claiming rows from `meta_pixel_deliveries` would therefore either lose
  # that data, gutting match quality for the majority of events, or require
  # writing it to a table, which is the thing the schema exists to avoid.
  #
  # So the buffer holds the same arguments the per-event job used to take, in
  # Redis, where they age out rather than accumulating.
  #
  # ## Losing the buffer is survivable
  #
  # Every entry has a `pending` row in `meta_pixel_deliveries` behind it. If
  # Redis is flushed, or a flush dies between draining and sending, those rows
  # are picked up by `RecoverDeliveries` once they pass its grace period. A lost
  # buffer costs the transient matching data on the recovered events, not the
  # conversions themselves.
  module BatchBuffer
    module_function

    KEY = "meta_pixel_capi_batch"

    # Redis holds the buffer for at most this long without a flush touching it.
    # Far inside Meta's 48-hour deduplication window, so an entry that somehow
    # survives this long has already been recovered from Postgres instead.
    TTL = 12.hours

    # A ceiling so a persistently failing flush cannot grow the buffer without
    # bound. Past it, dispatch stops buffering and leaves the row for
    # `RecoverDeliveries`, which is slower but bounded.
    MAX_ENTRIES = 10_000

    # @return [Integer, nil] the buffer length after the push, or nil if the
    #   buffer is full or Redis is unavailable.
    def push(args)
      entry = args.merge(enqueued_at: Time.now.to_i)

      return nil if size >= MAX_ENTRIES

      length = Discourse.redis.rpush(KEY, entry.to_json)
      Discourse.redis.expire(KEY, TTL.to_i)
      length
    rescue ::Redis::BaseError
      # Buffering is best effort. The delivery row is already claimed, so
      # `RecoverDeliveries` will find it.
      nil
    end

    # Atomically remove and return up to `limit` entries.
    #
    # `LPOP key count` is atomic, so two workers flushing at the same time
    # cannot take the same entry.
    def drain(limit)
      raw = Discourse.redis.lpop(KEY, limit)
      Array(raw).filter_map { |json| parse(json) }
    rescue ::Redis::BaseError
      []
    end

    # Put entries back at the front, oldest first, so they go out ahead of
    # newer ones. Age matters here: an event that misses Meta's deduplication
    # window stops being deduplicated and starts being double counted.
    def requeue(entries)
      return if entries.blank?

      # LPUSH with several values pushes them one at a time onto the head, so
      # the list ends up holding them backwards. Reversing first is what keeps
      # a requeued batch in its original order.
      Discourse.redis.lpush(KEY, entries.reverse.map(&:to_json))
      Discourse.redis.expire(KEY, TTL.to_i)
    rescue ::Redis::BaseError
      nil
    end

    # Read without removing. For diagnostics and for tests that need to see
    # what is queued without consuming it.
    def peek(limit = 100)
      raw = Discourse.redis.lrange(KEY, 0, limit - 1)
      Array(raw).filter_map { |json| parse(json) }
    rescue ::Redis::BaseError
      []
    end

    def size
      Discourse.redis.llen(KEY)
    rescue ::Redis::BaseError
      0
    end

    def clear
      Discourse.redis.del(KEY)
    rescue ::Redis::BaseError
      nil
    end

    # Age of the oldest entry in seconds, or nil when the buffer is empty.
    def oldest_age
      json = Discourse.redis.lindex(KEY, 0)
      return nil if json.blank?

      enqueued_at = parse(json)&.dig(:enqueued_at)
      return nil if enqueued_at.blank?

      [Time.now.to_i - enqueued_at.to_i, 0].max
    rescue ::Redis::BaseError
      nil
    end

    def parse(json)
      JSON.parse(json).symbolize_keys
    rescue JSON::ParserError, TypeError
      # An entry we cannot read is dropped rather than retried forever. Its
      # delivery row is still pending, so recovery picks it up.
      nil
    end
  end
end
