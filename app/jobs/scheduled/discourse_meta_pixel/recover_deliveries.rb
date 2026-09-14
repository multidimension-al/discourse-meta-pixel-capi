# frozen_string_literal: true

module Jobs
  module DiscourseMetaPixel
    # Re-enqueues deliveries that were claimed but never delivered.
    #
    # ## The gap this closes
    #
    # Dispatching is two steps: claim a row in `meta_pixel_deliveries`, then
    # enqueue a Sidekiq job. The claim is what makes the operation idempotent —
    # a later attempt at the same logical event sees the row and stops.
    #
    # That is exactly right while both steps succeed, and wrong if the second
    # one does not. If Redis is briefly unreachable, or the process dies between
    # the two, the row exists with no job behind it, and the idempotency check
    # now works against us: every replay is turned away as a duplicate, and the
    # conversion is lost silently and permanently. The same happens to a
    # `retrying` delivery whose job is lost — Sidekiq exhausting its retries,
    # a queue being flushed, a Redis restart without persistence.
    #
    # Purging only handles *settled* rows, so nothing else would ever notice.
    # This sweep is what makes "durable delivery" true rather than
    # aspirational.
    #
    # ## Why the heuristics are what they are
    #
    # A healthy job runs within seconds of being enqueued and records an
    # attempt. So a `pending` row with **zero attempts** that is older than the
    # grace period had no job behind it: nothing else can produce that state.
    #
    # A `retrying` row is mid-backoff. The backoff tops out at three hours, so
    # a row untouched for longer than that has no live job either. Re-enqueueing
    # one that *is* still live would be harmless anyway — the job is idempotent
    # and returns early on an already-succeeded delivery — but the window keeps
    # it from happening routinely.
    class RecoverDeliveries < ::Jobs::Scheduled
      every 30.minutes

      # Long enough that a merely slow queue is not mistaken for a lost job.
      PENDING_GRACE = 15.minutes

      # Comfortably beyond the job's own maximum backoff of three hours.
      RETRY_GRACE = 6.hours

      # A ceiling across all recovery attempts, so a delivery that fails in a
      # way the classifier cannot see as permanent still stops eventually
      # rather than being resurrected forever.
      MAX_TOTAL_ATTEMPTS = 12

      # Past Meta's seven-day event_time window a delivery can only be
      # rejected, so recovering it would just burn requests.
      MAX_EVENT_AGE = 7.days

      # A bound on work per run, so a large backlog is drained over several
      # runs instead of flooding the queue in one.
      BATCH_SIZE = 500

      def execute(_args)
        return unless SiteSetting.discourse_meta_pixel_enabled

        abandon_exhausted!
        abandon_too_old!

        return unless ::DiscourseMetaPixel::Dispatcher.enabled?

        recoverable.limit(BATCH_SIZE).find_each { |delivery| requeue(delivery) }
      end

      private

      def model
        ::DiscourseMetaPixel::Delivery
      end

      # Rows whose job is gone.
      def recoverable
        stranded =
          model
            .pending
            .where(attempts: 0)
            .where("created_at < ?", PENDING_GRACE.ago)

        stalled =
          model
            .retrying
            .where("attempts < ?", MAX_TOTAL_ATTEMPTS)
            .where(
              "last_attempted_at IS NULL OR last_attempted_at < ?",
              RETRY_GRACE.ago,
            )

        model.where(id: stranded.select(:id)).or(model.where(id: stalled.select(:id)))
      end

      # Give up on rows that have been resurrected too many times. Leaving them
      # `retrying` forever would make the diagnostics "retrying" count
      # meaningless as a signal that something needs attention.
      def abandon_exhausted!
        model
          .retrying
          .where("attempts >= ?", MAX_TOTAL_ATTEMPTS)
          .update_all(
            status: model.statuses[:failed],
            last_error: "recovery_exhausted",
            updated_at: Time.zone.now,
          )
      end

      def abandon_too_old!
        model
          .where(status: model.statuses.values_at(:pending, :retrying))
          .where("created_at < ?", MAX_EVENT_AGE.ago)
          .update_all(
            status: model.statuses[:failed],
            last_error: "event_too_old",
            updated_at: Time.zone.now,
          )
      end

      # Rebuild the job arguments from the row.
      #
      # Only the identity and the subject reference are stored, which is all a
      # server-authoritative event needs — the job reconstructs the rest and
      # derives `event_time` from the subject's own `created_at`.
      #
      # A recovered *browser* event has lost its transient matching data (the
      # IP, user agent and Meta cookies that lived in the vanished job
      # payload). It is still worth delivering: a conversion with weaker
      # matching beats a conversion that never arrives, and `_fbp`-less events
      # are explicitly supported by Meta.
      def requeue(delivery)
        ::DiscourseMetaPixel::Dispatcher.enqueue(
          event_name: delivery.event_name,
          event_id: delivery.event_id,
          object_type: delivery.subject_type,
          object_id: delivery.subject_id,
          user_id: delivery.subject_type == "user" ? delivery.subject_id : nil,
          event_time: nil,
        )

        delivery.update_columns(status: model.statuses[:retrying], updated_at: Time.zone.now)
      end
    end
  end
end
