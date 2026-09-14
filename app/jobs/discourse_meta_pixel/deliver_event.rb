# frozen_string_literal: true

module Jobs
  module DiscourseMetaPixel
    # Delivers one conversion to Meta, out of band.
    #
    # No forum request ever waits on this. Posting, registering and reading all
    # complete without a Meta round trip; this runs afterwards, in Sidekiq,
    # with Discourse's ordinary retry machinery rather than a bespoke loop.
    #
    # Retry policy comes from the client's classification of the response:
    #
    #   success    mark succeeded, done
    #   retryable  raise, so Sidekiq retries with backoff (network, 429, 5xx,
    #              and the Graph API codes Meta documents as transient)
    #   permanent  mark failed, return without raising, so it is never retried
    #              (an invalid token, a rejected payload, an unrecognised 4xx)
    #
    # Raising is what hands control to Sidekiq. Returning is what stops the
    # retries. Getting that the wrong way round is how a queue fills up with
    # requests that can never succeed.
    class DeliverEvent < ::Jobs::Base
      sidekiq_options retry: 5

      # Roughly 1m, 5m, 15m, 1h, 3h. Meta is not latency-sensitive for these
      # events — `event_time` may be up to seven days old — so backing off
      # generously costs nothing and is kinder to a rate limit.
      sidekiq_retry_in { |count, _exception| [60, 300, 900, 3600, 10_800][count] || 10_800 }

      # Meta's limit on how far in the past `event_time` may be.
      MAX_EVENT_AGE = ::DiscourseMetaPixel::EventAssembler::MAX_EVENT_AGE

      def execute(args)
        event_name = args[:event_name]
        event_id = args[:event_id]

        delivery =
          ::DiscourseMetaPixel::Delivery.find_by(event_name: event_name, event_id: event_id)
        return if delivery.nil?
        return if delivery.succeeded?

        unless ::DiscourseMetaPixel::Dispatcher.enabled?
          # Turned off between enqueue and execution. Not an error, and not
          # something to keep retrying.
          delivery.record_attempt!(status: :failed, error: "plugin_disabled")
          return
        end

        event = build_event(args)
        if event.nil?
          # The subject was deleted, or is no longer publicly visible, between
          # enqueue and delivery. Correct outcome: send nothing.
          delivery.record_attempt!(status: :failed, error: "subject_ineligible")
          return
        end

        # Meta: "event_time can be up to 7 days before you send an event to
        # Meta." Past that the request can only be rejected, so it is not worth
        # sending — and it must not keep retrying, or a delivery stranded by an
        # outage would retry forever against a deadline it can never meet.
        if event[:event_time] < MAX_EVENT_AGE.ago.to_i
          delivery.record_attempt!(status: :failed, error: "event_too_old")
          return
        end

        result = client.send_events([event])

        if result.success?
          delivery.record_attempt!(status: :succeeded)
          return
        end

        error = error_label(result)

        if result.permanent?
          delivery.record_attempt!(status: :failed, error: error)
          return
        end

        delivery.record_attempt!(status: :retrying, error: error)
        raise DeliveryError, "meta capi #{error}"
      end

      class DeliveryError < StandardError
      end

      private

      def client
        ::DiscourseMetaPixel::EventAssembler.client
      end

      def build_event(args)
        ::DiscourseMetaPixel::EventAssembler.build(args)
      end

      def error_label(result)
        ::DiscourseMetaPixel::EventAssembler.error_label(result)
      end
    end
  end
end
