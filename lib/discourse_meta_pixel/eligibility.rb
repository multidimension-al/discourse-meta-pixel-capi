# frozen_string_literal: true

module DiscourseMetaPixel
  # Decides whether a piece of content may produce a Meta event at all.
  #
  # The rule this plugin enforces is stronger than "strip the identifying
  # fields": for excluded content **the event does not happen**. Sending a
  # parameter-free `ViewContent` for a private message would still tell Meta
  # that someone read a private message, when, and how often. So the answer is
  # no event.
  #
  # Public visibility is established with Discourse's own permission system —
  # an anonymous `Guardian` — rather than by pattern-matching a URL. A
  # restricted category, a staff-only category, a personal message, a
  # login-required site and a topic that has since been deleted are then all
  # handled by the same authoritative check, including cases this plugin has
  # not thought of.
  module Eligibility
    module_function

    # Would a logged-out visitor be able to read this topic?
    #
    # This is the question that matters. A topic an anonymous visitor can read
    # is public content; anything else is somebody's private or privileged
    # material, whatever route it is served from.
    def publicly_visible_topic?(topic)
      return false if topic.blank?
      return false if topic.private_message?
      return false if topic.archetype == Archetype.private_message
      return false if SiteSetting.login_required?

      # `Guardian.new` with no user is the anonymous guardian. Delegating here
      # means category permissions, group permissions, deleted and unlisted
      # topics and any future visibility rule are all respected without this
      # plugin restating them.
      Guardian.new.can_see_topic?(topic)
    rescue StandardError
      # Failing closed is the only safe direction: an exception while deciding
      # whether something is public must not be read as "yes".
      false
    end

    def publicly_visible_post?(post)
      return false if post.blank?

      publicly_visible_topic?(post.topic)
    end

    # Route paths that must never produce a content event, checked in addition
    # to the topic-level permission check above.
    #
    # This is defence in depth, not the primary mechanism. It exists because
    # the browser reports the path it was on for `PageView`, where there is no
    # topic to consult, and because an obviously sensitive route should be
    # refused even if a future change made the permission check reachable in a
    # surprising state.
    SENSITIVE_PATH_PATTERNS = [
      %r{\A/admin(/|\z)},
      %r{\A/review(/|\z)},
      %r{\A/safe-mode(/|\z)},
      %r{\A/my/},
      %r{\A/u/[^/]+/messages(/|\z)},
      %r{\A/u/[^/]+/preferences(/|\z)},
      %r{\A/u/[^/]+/summary/private},
      %r{\A/topics/private-messages(/|\z)},
      %r{\A/session/},
      %r{\A/u/password-reset(/|\z)},
      %r{\A/u/activate-account(/|\z)},
      %r{\A/u/email-login(/|\z)},
      %r{\A/u/confirm-},
      %r{\A/invites/},
      %r{\A/associate/},
      %r{\A/auth/},
    ].freeze

    def sensitive_path?(path)
      value = path.to_s.split("?").first.to_s
      value = "/#{value}" unless value.start_with?("/")

      SENSITIVE_PATH_PATTERNS.any? { |pattern| pattern.match?(value) }
    end

    # Events the browser is allowed to mirror to the server. Anything else the
    # endpoint refuses outright — the browser cannot name an arbitrary Meta
    # event.
    # Whether this person's activity must produce no Meta event at all.
    #
    # Unlike the GA plugin, which tags internal traffic and lets Google filter
    # it, there is no `traffic_type` equivalent in Meta's model: an event that
    # arrives has already been counted and can already train a campaign. So the
    # only honest exclusion is not to send it.
    #
    # Checked on the server for every dispatch path, not only in the browser,
    # because `TopicCreated`, `ReplyCreated` and `CompleteRegistration` are
    # raised from `DiscourseEvent` and never involve a browser at all — a
    # browser-only check would silently leak exactly the conversions that
    # matter most.
    def excluded_user?(user)
      return false if user.blank?

      group_ids = SiteSetting.meta_pixel_excluded_groups_map
      return false if group_ids.blank?

      user = User.find_by(id: user) if user.is_a?(Integer) || user.is_a?(String)
      return false if user.blank?

      user.in_any_groups?(group_ids)
    end

    MIRRORED_EVENTS = %w[PageView ViewContent Search TopicEngaged].freeze

    # Events only the server ever originates.
    SERVER_EVENTS = %w[CompleteRegistration TopicCreated ReplyCreated].freeze

    def mirrored_event?(name)
      MIRRORED_EVENTS.include?(name.to_s)
    end

    # Per-event site setting. An event with no setting behind it cannot be
    # sent, which is what makes "unknown event names are refused" meaningful.
    EVENT_SETTINGS = {
      "PageView" => :meta_pixel_track_page_view,
      "ViewContent" => :meta_pixel_track_view_content,
      "Search" => :meta_pixel_track_search,
      "TopicEngaged" => :meta_pixel_track_topic_engaged,
      "CompleteRegistration" => :meta_pixel_track_complete_registration,
      "TopicCreated" => :meta_pixel_track_topic_created,
      "ReplyCreated" => :meta_pixel_track_reply_created,
    }.freeze

    def event_enabled?(name)
      setting = EVENT_SETTINGS[name.to_s]
      return false if setting.nil?

      !!SiteSetting.public_send(setting)
    end
  end
end
