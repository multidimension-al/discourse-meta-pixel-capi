# frozen_string_literal: true

require "digest"

module DiscourseMetaPixel
  # Event identity.
  #
  # Meta deduplicates a browser Pixel event against a Conversions API event
  # when **both the event name and the event ID match**, within a 48 hour
  # window. Getting that wrong does not fail loudly — it silently doubles every
  # conversion — so event identity is generated in exactly one place.
  #
  # There are two kinds of identity, and the difference is deliberate:
  #
  # * **Browser-originated events** (PageView, ViewContent, Search,
  #   TopicEngaged) have no authoritative server object to key off. The browser
  #   generates one random ID, gives it to `fbq` as `eventID`, and sends the
  #   same value to this plugin's endpoint, which passes it through to CAPI as
  #   `event_id`. One value, generated once, used twice.
  #
  # * **Server-authoritative events** (CompleteRegistration, TopicCreated,
  #   ReplyCreated) key off the object that actually happened. The ID is a pure
  #   function of (event name, object type, object id), so a retry, a replayed
  #   lifecycle hook or a re-enqueued job all produce the same ID and Meta
  #   treats them as one conversion.
  #
  # This module has no Rails dependency so the derivation can be tested
  # directly; see spec/standalone.
  module EventId
    # A browser-generated ID is 32 lowercase hex characters (128 bits from
    # `crypto.getRandomValues`). The endpoint enforces this exactly: an ID it
    # did not shape is an ID it cannot vouch for.
    BROWSER_PATTERN = /\A[0-9a-f]{32}\z/

    # Any ID this plugin will accept anywhere, browser or derived.
    ANY_PATTERN = /\A[0-9a-f]{32,64}\z/

    NAMESPACE = "discourse-meta-pixel"

    module_function

    def valid_browser_id?(value)
      return false if value.nil?

      BROWSER_PATTERN.match?(value.to_s)
    end

    def valid?(value)
      return false if value.nil?

      ANY_PATTERN.match?(value.to_s)
    end

    # Deterministic identity for a server-authoritative event.
    #
    # Hashed rather than sent as a readable string like
    # "discourse:TopicCreated:topic:123": the ID travels to Meta, and there is
    # no reason to hand them a decodable object reference when an opaque stable
    # token deduplicates just as well.
    #
    # `site` scopes the namespace so two Discourse instances sharing one Meta
    # dataset cannot collide on, say, topic 1.
    #
    # This is not a secret and does not need to be: it is a deduplication key,
    # not a credential. Nothing is authorised by presenting it.
    def derive(event_name:, object_type:, object_id:, site:)
      raise ArgumentError, "event_name required" if event_name.to_s.empty?
      raise ArgumentError, "object_type required" if object_type.to_s.empty?
      raise ArgumentError, "object_id required" if object_id.to_s.empty?

      Digest::SHA256.hexdigest(
        [NAMESPACE, site, event_name, object_type, object_id].join(":"),
      )
    end
  end
end
