# frozen_string_literal: true

module Jobs
  module DiscourseMetaPixel
    # Sends one batch of conversions to Meta.
    #
    # A topic visit produces two or three deliveries, so a forum of any size
    # produces far more of them than it does topics. Sending each one in its own
    # job and its own HTTPS request is correct but wasteful; Meta accepts up to
    # 1,000 events per request, and batching turns thousands of requests a day
    # into dozens.
    #
    # ## What bounds the delay
    #
    # Not Meta's `event_time` window, which is seven days. The real ceiling is
    # **deduplication**: the browser Pixel fires immediately, and Meta only
    # matches the server copy to it within 48 hours. Past that the two stop
    # being one event and start being two conversions — inflated numbers rather
    # than missing ones, which is the worse failure because it looks fine.
    #
    # The flush window is minutes, so there is a wide margin. `MAX_AGE` is the
    # backstop that sends a straggler alone rather than letting it wait for a
    # batch that never fills.
    #
    # ## Partial failure
    #
    # Meta's `/events` endpoint accepts or rejects a request as a whole; there
    # is no per-event verdict in a normal response. So a single malformed event
    # rejects its ninety-nine healthy neighbours.
    #
    # Marking the whole batch failed would lose those ninety-nine. Instead a
    # permanent failure of a multi-event batch is retried event by event, over
    # one held-open connection, until each has its own outcome. That costs one
    # extra pass only in the rare case Meta actually rejects something.
    class FlushBatch < ::Jobs::Base
      sidekiq_options retry: 3

      def execute(_args)
        return unless ::DiscourseMetaPixel::Dispatcher.enabled?

        # Meta has rate limited us recently. Leave the buffer alone rather than
        # draining it only to be refused; the scheduled flush comes back round.
        return if ::DiscourseMetaPixel::Throttle.throttled?

        entries = ::DiscourseMetaPixel::BatchBuffer.drain(batch_size)
        return if entries.empty?

        prepared = entries.filter_map { |entry| prepare(entry) }
        return if prepared.empty?

        deliver(prepared)
      end

      private

      def assembler
        ::DiscourseMetaPixel::EventAssembler
      end

      def batch_size
        SiteSetting.meta_pixel_batch_size
      end

      # Resolve an entry to a deliverable event, or settle it and drop it.
      #
      # Everything here is a reason to send nothing rather than an error, so
      # each records its own outcome on the row and returns nil.
      def prepare(args)
        delivery =
          ::DiscourseMetaPixel::Delivery.find_by(
            event_name: args[:event_name],
            event_id: args[:event_id],
          )
        return nil if delivery.nil?
        return nil if delivery.succeeded?

        event = assembler.build(args)
        if event.nil?
          # The subject was deleted, or stopped being publicly visible, between
          # dispatch and delivery.
          delivery.record_attempt!(status: :failed, error: "subject_ineligible")
          return nil
        end

        if event[:event_time] < ::DiscourseMetaPixel::EventAssembler::MAX_EVENT_AGE.ago.to_i
          # Past Meta's seven-day window the request can only be rejected.
          delivery.record_attempt!(status: :failed, error: "event_too_old")
          return nil
        end

        { args: args, delivery: delivery, event: event }
      end

      def deliver(prepared)
        capi = assembler.client
        result = capi.send_events(prepared.map { |p| p[:event] })

        return succeed(prepared) if result.success?
        return retry_later(prepared, result) if result.retryable?
        return fail_one(prepared.first, result) if prepared.length == 1

        isolate(capi, prepared)
      end

      def succeed(prepared)
        prepared.each { |p| p[:delivery].record_attempt!(status: :succeeded) }
      end

      # A transient failure is the whole batch's, so the whole batch goes back.
      # Re-sending an event Meta already accepted is safe: the shared event id
      # is what deduplication matches on.
      def retry_later(prepared, result)
        # A 429 is not this batch's problem, it is the whole plugin's. Standing
        # every flush down together is what stops a rate limit becoming a
        # sustained one.
        if result.http_status == 429
          ::DiscourseMetaPixel::Throttle.back_off!(result.retry_after)
        end

        error = assembler.error_label(result)
        prepared.each { |p| p[:delivery].record_attempt!(status: :retrying, error: error) }
        ::DiscourseMetaPixel::BatchBuffer.requeue(prepared.map { |p| p[:args] })
      end

      def fail_one(prepared, result)
        prepared[:delivery].record_attempt!(status: :failed, error: assembler.error_label(result))
      end

      # Meta rejected the batch and will not say which event caused it. Send
      # them individually so the healthy ones still land and only the offender
      # is marked failed.
      def isolate(capi, prepared)
        capi.with_connection do |conn|
          prepared.each do |p|
            one = conn.send_events([p[:event]])

            if one.success?
              p[:delivery].record_attempt!(status: :succeeded)
            elsif one.retryable?
              p[:delivery].record_attempt!(
                status: :retrying,
                error: assembler.error_label(one),
              )
              ::DiscourseMetaPixel::BatchBuffer.requeue([p[:args]])
            else
              p[:delivery].record_attempt!(status: :failed, error: assembler.error_label(one))
            end
          end
        end
      end
    end
  end
end
