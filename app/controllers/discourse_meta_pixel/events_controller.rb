# frozen_string_literal: true

module DiscourseMetaPixel
  # The browser-to-server mirror endpoint.
  #
  # The browser has already fired the Pixel with an event id; this hands the
  # server the same id so the Conversions API copy deduplicates against it.
  #
  # ## What this endpoint is not
  #
  # It is not a Conversions API proxy. It accepts a deliberately tiny schema
  # and reconstructs everything else from the server's own knowledge:
  #
  #   accepted        event_name (from a fixed list of four)
  #                   event_id   (exactly 32 lowercase hex characters)
  #                   topic_id   (optional integer, re-checked for public
  #                               visibility with an anonymous Guardian)
  #                   path       (optional, must be a same-site path)
  #
  #   never accepted  user_data, custom_data, an access token, a destination
  #                   URL or host, a Graph API version or path, an event time,
  #                   an IP address, a user agent, fbp/fbc, or any parameter
  #                   not named above
  #
  # The identity of the person, their IP and user agent, and the `_fbp` /
  # `_fbc` first-party cookies are all taken from the actual request. A client
  # cannot assert who it is or where it is coming from.
  class EventsController < ::ApplicationController
    requires_plugin DiscourseMetaPixel::PLUGIN_NAME

    # Same-origin only, with Discourse's ordinary CSRF protection and the
    # inherited `check_xhr` filter left in place. The route's
    # `defaults: { format: :json }` already satisfies check_xhr for the
    # plugin's own AJAX call, so there is nothing to skip and skipping it would
    # only widen what the endpoint accepts.

    MAX_PATH_LENGTH = 512

    # Generous enough for real reading behaviour (a page view, a topic view and
    # an engagement event on each of several topics) and low enough that a
    # script cannot manufacture conversions in bulk. Keyed per user for signed
    # in visitors and per IP otherwise.
    RATE_LIMIT_COUNT = 60
    RATE_LIMIT_PERIOD = 1.minute

    def create
      return render_ok unless Dispatcher.enabled?

      rate_limit!

      event_name = params[:event_name].to_s
      event_id = params[:event_id].to_s

      # An event name the browser is not allowed to mirror is refused outright,
      # rather than being passed through to Meta.
      unless Eligibility.mirrored_event?(event_name)
        return render json: failed_json.merge(error: "unknown_event"), status: 422
      end

      unless EventId.valid_browser_id?(event_id)
        return render json: failed_json.merge(error: "invalid_event_id"), status: 422
      end

      topic = resolve_topic
      # ViewContent is about a specific piece of content. Without a topic the
      # server can vouch for, there is nothing to report.
      if event_name == "ViewContent" && topic.nil?
        return render json: failed_json.merge(error: "ineligible"), status: 422
      end

      source_url = resolve_source_url(topic)

      result =
        Dispatcher.dispatch_browser_event(
          event_name: event_name,
          event_id: event_id,
          user_id: current_user&.id,
          topic_id: topic&.id,
          event_source_url: source_url,
          request_context: request_context,
        )

      render json: { success: true, result: result.to_s }
    end

    private

    def rate_limit!
      # RateLimiter#build_key is "<prefix>:<user id>:<type>", so for an
      # anonymous visitor the user id is empty and every anonymous visitor
      # would otherwise share one bucket — which on a real forum would rate
      # limit the whole site to a handful of events a minute. Core's own
      # anonymous limits put the IP in the type for the same reason
      # (see anonymous_actions_controller.rb).
      key =
        if current_user
          "meta-pixel-events"
        else
          "meta-pixel-events-#{request.remote_ip}"
        end

      RateLimiter.new(current_user, key, RATE_LIMIT_COUNT, RATE_LIMIT_PERIOD).performed!
    end

    # Resolve the topic the browser named, then decide for ourselves whether it
    # may be reported. A topic id in a request body is a question, not a fact.
    def resolve_topic
      raw = params[:topic_id]
      return nil if raw.blank?

      id = raw.to_s
      return nil unless id.match?(/\A\d{1,18}\z/)

      topic = Topic.find_by(id: id.to_i)
      return nil unless Eligibility.publicly_visible_topic?(topic)

      topic
    end

    # Build `event_source_url` from something the server trusts.
    #
    # For a topic, from the topic itself. Otherwise from the browser-supplied
    # path, which is validated as a same-site path and then re-attached to this
    # site's own base URL — so it cannot name another host — and stripped down
    # to an allowlist of query parameters, so it cannot carry a token.
    def resolve_source_url(topic)
      return UrlSanitizer.for_topic(topic, Discourse.base_url) if topic

      path = params[:path].to_s
      return nil if path.empty? || path.length > MAX_PATH_LENGTH
      return nil if Eligibility.sensitive_path?(path)

      UrlSanitizer.build(path, Discourse.base_url)
    end

    # Matching data, taken from the request rather than from its body.
    #
    # `request.remote_ip` is Rails' resolution of the real client address,
    # honouring Discourse's proxy configuration. `_fbp` and `_fbc` are
    # first-party cookies on this domain that Meta's own Pixel wrote, so
    # reading them server-side is both more reliable and less forgeable than
    # accepting them as parameters. The plugin never fabricates either.
    def request_context
      {
        client_ip_address: request.remote_ip,
        client_user_agent: request.user_agent.to_s.slice(0, 512),
        fbp: cookies[:_fbp],
        fbc: cookies[:_fbc],
      }
    end

    def render_ok
      render json: { success: true, result: "disabled" }
    end
  end
end
