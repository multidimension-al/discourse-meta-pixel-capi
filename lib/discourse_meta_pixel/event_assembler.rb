# frozen_string_literal: true

module DiscourseMetaPixel
  # Turns stored delivery arguments back into a Conversions API event.
  #
  # Shared by the single-event job and the batch flush so there is one answer
  # to "what does this delivery actually send", rather than two that can drift.
  module EventAssembler
    module_function

    # Meta: "event_time can be up to 7 days before you send an event to
    # Meta." Past that a request can only be rejected.
    MAX_EVENT_AGE = 7.days

    # Rebuilt at delivery time rather than stored at enqueue time.
    #
    # For a server-authoritative event this means no personal data was ever
    # written to the database; for both kinds it means the event reflects the
    # state at delivery, so a topic deleted in the meantime does not get
    # reported.
    #
    # @return [Hash, nil] nil when the subject is gone or is no longer
    #   publicly visible, which is a reason to send nothing rather than an
    #   error.
    def build(args)
      topic = nil
      subject = nil
      user = args[:user_id].present? ? User.find_by(id: args[:user_id]) : nil

      case args[:object_type]
      when "topic"
        topic = Topic.find_by(id: args[:object_id])
        return nil unless Eligibility.publicly_visible_topic?(topic)
        subject = topic
      when "post"
        post = Post.find_by(id: args[:object_id])
        return nil unless Eligibility.publicly_visible_post?(post)
        topic = post.topic
        subject = post
      when "user"
        return nil if user.nil?
        subject = user
      end

      event_source_url = args[:event_source_url].presence
      if event_source_url.nil? && topic
        event_source_url = UrlSanitizer.for_topic(topic, Discourse.base_url)
      end

      EventBuilder.new.build(
        event_name: args[:event_name],
        event_id: args[:event_id],
        user: user,
        topic: topic,
        event_source_url: event_source_url,
        request_context: (args[:request_context] || {}).symbolize_keys,
        event_time: resolve_event_time(args, subject),
      )
    end

    # When the event actually happened.
    #
    # Never `Time.now`: that is when delivery *ran*, which on a backed-up queue
    # or after a retry can be hours later, and Meta uses `event_time` for
    # attribution. The dispatcher supplies the occurrence time, and because it
    # travels with the delivery it is identical across every retry.
    #
    # The subject's own `created_at` is the fallback rather than the clock, so
    # a delivery enqueued by an older version of this plugin, or re-enqueued by
    # the recovery sweep, still reports when the thing happened.
    def resolve_event_time(args, subject)
      supplied = args[:event_time].to_i
      return supplied if supplied.positive?

      created = subject.respond_to?(:created_at) ? subject&.created_at : nil
      (created || Time.now).to_i
    end

    # A short, non-identifying label. Meta's own message can quote the payload
    # back, and this ends up in a column an administrator reads.
    def error_label(result)
      parts = []
      parts << "http_#{result.http_status}" if result.http_status
      parts << "code_#{result.error_code}" if result.error_code
      parts << result.error_message if result.error_message && parts.empty?
      parts.join(" ").presence || "unknown"
    end

    def client
      CapiClient.new(
        dataset_id: SiteSetting.meta_pixel_dataset_id,
        access_token: SiteSetting.meta_pixel_capi_access_token,
        api_version: SiteSetting.meta_pixel_graph_api_version,
        test_event_code: SiteSetting.meta_pixel_test_event_code,
      )
    end
  end
end
