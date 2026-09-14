# frozen_string_literal: true

module DiscourseMetaPixel
  # Assembles a Conversions API server event.
  #
  # Everything reaching Meta is built here, from data the server itself holds.
  # The browser contributes an event name from a fixed list, an event id it
  # generated, and at most a path and a topic id — all of which are re-checked
  # before they are used. It never contributes `user_data`, `custom_data`, a
  # URL, or a field this method does not know about.
  class EventBuilder
    ACTION_SOURCE = "website"

    def initialize(site_settings: SiteSetting, base_url: Discourse.base_url)
      @site_settings = site_settings
      @base_url = base_url
    end

    # @param event_name [String]
    # @param event_id [String]
    # @param user [User, nil] resolved server-side, never supplied by a client
    # @param topic [Topic, nil] already checked for public visibility
    # @param event_source_url [String, nil] already canonicalised
    # @param request_context [Hash] ip, user agent, fbp, fbc from the real request
    # @param event_time [Integer] unix seconds
    def build(
      event_name:,
      event_id:,
      user: nil,
      topic: nil,
      event_source_url: nil,
      request_context: {},
      event_time: Time.now.to_i
    )
      event = {
        event_name: event_name,
        event_time: event_time,
        event_id: event_id,
        action_source: ACTION_SOURCE,
        user_data: user_data_for(user, request_context),
      }

      event[:event_source_url] = event_source_url if event_source_url.present?

      custom = custom_data_for(event_name, topic)
      event[:custom_data] = custom if custom.present?

      event
    end

    private

    def user_data_for(user, context)
      UserData.build(
        email: user&.email,
        user_id: user&.id,
        secret: external_id_secret,
        client_ip_address: context[:client_ip_address],
        client_user_agent: context[:client_user_agent],
        fbp: context[:fbp],
        fbc: context[:fbc],
        enhanced_email: @site_settings.meta_pixel_enhanced_email_matching,
        external_id_enabled: @site_settings.meta_pixel_external_id_matching,
      )
    end

    # Discourse's own secret key base, rather than a new secret setting for an
    # administrator to generate, store and eventually leak. It never leaves the
    # server and never appears in a payload; only the HMAC of a user id does.
    def external_id_secret
      GlobalSetting.safe_secret_key_base
    end

    # Custom data is intentionally sparse.
    #
    # Meta is an attribution and optimisation surface, not a telemetry sink,
    # and every field added here is a field to justify. Topic titles are never
    # included: they are user-generated and routinely contain personal detail.
    def custom_data_for(event_name, topic)
      return nil if topic.blank?
      return nil unless %w[ViewContent TopicCreated ReplyCreated TopicEngaged].include?(event_name)

      data = { content_type: "topic" }

      # Only reached for topics that already passed the public-visibility
      # check, but the guard is repeated because this method could otherwise be
      # called from somewhere that had not.
      return data unless Eligibility.publicly_visible_topic?(topic)

      data[:content_ids] = [topic.id.to_s]
      data[:content_category] = topic.category&.slug if topic.category_id.present?
      data
    end
  end
end
