# frozen_string_literal: true

module DiscourseMetaPixel
  # The single entry point for creating a Conversions API conversion.
  #
  # Owns the answer to "who fires this event" for every event the plugin sends,
  # and owns the claim on the idempotency table. Nothing else enqueues a
  # delivery job.
  module Dispatcher
    module_function

    def enabled?
      SiteSetting.discourse_meta_pixel_enabled && SiteSetting.meta_pixel_capi_enabled &&
        SiteSetting.meta_pixel_dataset_id.present? &&
        SiteSetting.meta_pixel_capi_access_token.present?
    end

    # A server-authoritative conversion: registration, topic creation, reply
    # creation.
    #
    # The event id is derived from the object, so this is safe to call more
    # than once for the same object — a replayed `DiscourseEvent`, a
    # re-imported record, a retried job — and the second call is a no-op.
    #
    # @return [Symbol] :enqueued, :duplicate, or a reason it was skipped
    def dispatch_server_event(
      event_name:,
      object_type:,
      object_id:,
      user_id: nil,
      event_time: nil,
      request_context: nil
    )
      return :disabled unless enabled?
      return :event_disabled unless Eligibility.event_enabled?(event_name)
      return :unknown_event unless Eligibility::SERVER_EVENTS.include?(event_name)

      event_id =
        EventId.derive(
          event_name: event_name,
          object_type: object_type,
          object_id: object_id,
          site: site_namespace,
        )

      _, created =
        Delivery.claim(
          event_name: event_name,
          event_id: event_id,
          source: "server",
          subject_type: object_type,
          subject_id: object_id,
        )

      # Already claimed: the conversion exists. Enqueueing again is exactly the
      # duplicate the table is here to prevent.
      return :duplicate unless created

      enqueue(
        event_name: event_name,
        event_id: event_id,
        object_type: object_type,
        object_id: object_id,
        user_id: user_id,
        event_time: event_time,
        request_context: request_context,
      )

      :enqueued
    end

    # A browser-mirrored conversion: the Pixel already fired with this event
    # id, and CAPI now sends the same event id so Meta deduplicates the pair.
    #
    # The event id comes from the browser by necessity — it has to be the same
    # value the Pixel used — which is why the endpoint validates its shape and
    # why the claim below is what stops a caller replaying one.
    #
    # `request_context` is built by the controller from the actual request, not
    # from the request body.
    def dispatch_browser_event(
      event_name:,
      event_id:,
      request_context:,
      user_id: nil,
      topic_id: nil,
      event_source_url: nil,
      event_time: nil
    )
      return :disabled unless enabled?
      return :unknown_event unless Eligibility.mirrored_event?(event_name)
      return :event_disabled unless Eligibility.event_enabled?(event_name)
      return :invalid_event_id unless EventId.valid_browser_id?(event_id)
      return :excluded_user if Eligibility.excluded_user?(user_id)

      _, created =
        Delivery.claim(
          event_name: event_name,
          event_id: event_id,
          source: "browser",
          subject_type: topic_id.present? ? "topic" : nil,
          subject_id: topic_id,
        )

      return :duplicate unless created

      enqueue(
        event_name: event_name,
        event_id: event_id,
        object_type: topic_id.present? ? "topic" : nil,
        object_id: topic_id,
        user_id: user_id,
        event_source_url: event_source_url,
        # When the visitor actually did this, captured at the request rather
        # than read off the clock when the job happens to run.
        event_time: event_time || Time.now.to_i,
        # Transient matching data. Lives in the Sidekiq payload for the
        # lifetime of the job and its retries, and is never written to the
        # database.
        request_context: request_context,
      )

      :enqueued
    end

    # Single enqueue point, so the recovery sweep can re-enqueue an abandoned
    # delivery with exactly the arguments the original would have had.
    def enqueue(
      event_name:,
      event_id:,
      object_type: nil,
      object_id: nil,
      user_id: nil,
      event_source_url: nil,
      event_time: nil,
      request_context: nil
    )
      args = {
        event_name: event_name,
        event_id: event_id,
        object_type: object_type,
        object_id: object_id,
        user_id: user_id,
        event_source_url: event_source_url,
        event_time: event_time,
        request_context: request_context,
      }

      # Buffered rather than sent one job per event: a topic visit produces two
      # or three of these, and Meta takes up to 1000 per request.
      length = BatchBuffer.push(args)

      if length.nil?
        # The buffer is full or Redis is unreachable. The delivery row is
        # already claimed, so fall back to a job of its own rather than drop
        # the conversion.
        Jobs.enqueue(Jobs::DiscourseMetaPixel::DeliverEvent, **args)
        return
      end

      # Full batches go immediately; anything short of full waits for the
      # scheduled flush.
      if length >= SiteSetting.meta_pixel_batch_size
        Jobs.enqueue(Jobs::DiscourseMetaPixel::FlushBatch)
      end
    end

    # Namespaces derived event ids so two Discourse instances sharing one Meta
    # dataset cannot collide on the same object id.
    def site_namespace
      Discourse.current_hostname
    end

    # ---------------------------------------------------------------------
    # Event ownership
    # ---------------------------------------------------------------------
    #
    # `post_created` fires for *every* post, including the first post of a new
    # topic, and `topic_created` fires as well for that first post
    # (lib/post_creator.rb#trigger_after_events fires both). Interpreting that
    # in one place is what stops a new topic reporting as a TopicCreated *and*
    # a ReplyCreated.
    #
    # The rule: a first post is a topic, anything else is a reply. The plugin
    # therefore ignores `topic_created` entirely and derives both events from
    # `post_created`, so there is one hook and one decision.
    def handle_post_created(post)
      return :ineligible if post.blank?
      return :ineligible unless Eligibility.publicly_visible_post?(post)
      return :excluded_user if Eligibility.excluded_user?(post.user_id)

      # `event_time` is when the post was actually made, not when the delivery
      # job happens to run. Meta accepts an event_time up to seven days old and
      # uses it for attribution, so reporting the job's execution time would
      # quietly misattribute every conversion by the length of the queue.
      occurred_at = (post.created_at || Time.now).to_i

      if post.is_first_post?
        dispatch_server_event(
          event_name: "TopicCreated",
          object_type: "topic",
          object_id: post.topic_id,
          user_id: post.user_id,
          event_time: occurred_at,
        )
      else
        dispatch_server_event(
          event_name: "ReplyCreated",
          object_type: "post",
          object_id: post.id,
          user_id: post.user_id,
          event_time: occurred_at,
        )
      end
    end

    # Registration is deliberately *not* dispatched here.
    #
    # At `:user_created` there is no request, so a conversion sent now would
    # carry no IP, no user agent, no _fbp/_fbc and no browser copy to
    # deduplicate against — the worst-matched event in the plugin, for the most
    # valuable conversion. Instead a marker is recorded and the next
    # authenticated render turns it into a properly matched browser+server
    # pair. See lib/discourse_meta_pixel/registration_signal.rb.
    def handle_user_created(user)
      return :ineligible if user.blank?
      return :disabled unless enabled?
      return :event_disabled unless Eligibility.event_enabled?("CompleteRegistration")
      return :ineligible unless RegistrationSignal.genuine_registration?(user)
      return :excluded_user if Eligibility.excluded_user?(user)

      RegistrationSignal.record(user) ? :marker_recorded : :ineligible
    end

    # Consume a pending registration marker during an authenticated render and
    # dispatch the Conversions API half of the pair.
    #
    # @return [String, nil] the shared event id, for the browser to fire the
    #   Pixel with. nil when there was nothing pending.
    def consume_registration(user, request_context)
      return nil if user.blank?
      return nil unless enabled?
      return nil unless Eligibility.event_enabled?("CompleteRegistration")
      return nil if Eligibility.excluded_user?(user)

      event_id = RegistrationSignal.consume(user.id)
      return nil if event_id.blank?

      # Outside Meta's seven-day event_time window the request could only be
      # rejected, so it is dropped rather than queued to fail.
      return nil unless RegistrationSignal.within_event_window?(user.created_at)

      _, created =
        Delivery.claim(
          event_name: "CompleteRegistration",
          event_id: event_id,
          source: "browser",
          subject_type: "user",
          subject_id: user.id,
        )

      if created
        enqueue(
          event_name: "CompleteRegistration",
          event_id: event_id,
          object_type: "user",
          object_id: user.id,
          user_id: user.id,
          # The registration happened when the account was created, not when
          # this page was rendered.
          event_time: user.created_at.to_i,
          request_context: request_context,
        )
      end

      # Returned whether or not this call created the row: the browser half may
      # legitimately need firing again (a failed request, a reload) and Meta
      # deduplicates on the id.
      event_id
    end
  end
end
