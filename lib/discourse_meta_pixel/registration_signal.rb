# frozen_string_literal: true

module DiscourseMetaPixel
  # Carries a pending `CompleteRegistration` across the page reload that
  # Discourse's signup flow performs.
  #
  # ## Why this exists
  #
  # Dispatching `CompleteRegistration` straight from `:user_created` works, but
  # produces the *worst matched* conversion in the plugin — and it is the most
  # valuable one. At that moment there is no request to draw from, so the event
  # goes to Meta with no client IP, no user agent, no `_fbp`, no `_fbc` and no
  # `event_source_url`, and with no browser Pixel copy to deduplicate against.
  # `PageView` ends up better matched than the registration it led to.
  #
  # So registration is handled in two steps instead:
  #
  #   1. `:user_created` records a marker holding the **deterministic event id**
  #      for that user, and nothing is sent yet.
  #   2. The next authenticated HTML render consumes the marker. That render is
  #      a real request, so it has the IP, user agent and first-party Meta
  #      cookies — and it can emit a meta tag telling the browser to fire the
  #      Pixel with **the same event id**.
  #
  # The result is a properly deduplicated browser+server pair with full
  # matching data, using the same shared-id mechanism as the other mirrored
  # events.
  #
  # `event_time` is *not* the moment the marker is consumed — it stays the
  # account's `created_at`, because that is when the registration actually
  # happened.
  #
  # ## Consequences worth stating
  #
  # A registration only becomes a conversion once the account loads an
  # authenticated page. An account that is created and never used produces
  # nothing, which is the desirable behaviour: it filters unactivated signups,
  # and it means staged, imported and bot accounts cannot generate conversions
  # even if the eligibility filter missed one.
  #
  # The marker TTL is 7 days, matching Meta's limit on how old `event_time` may
  # be. A marker that outlived that window could only produce a rejected
  # request, so it is allowed to expire instead.
  module RegistrationSignal
    # Meta: "event_time can be up to 7 days before you send an event to Meta."
    TTL = 7.days
    MAX_EVENT_AGE = 7.days

    module_function

    def key(user_id)
      "discourse_meta_pixel:registration:#{user_id}"
    end

    # Is this a registration a human actually performed?
    #
    # `:user_created` is an after-commit hook on every new User row, which
    # includes rows that are not signups at all. Counting those as ad-driven
    # conversions would corrupt the one metric the campaign is optimised
    # against.
    def genuine_registration?(user)
      return false if user.blank?
      # id > 0. Excludes the system user and every bot account.
      return false unless user.human?
      # Created by Discourse to receive incoming email, not by a person.
      return false if user.staged?
      # Set by import scripts on the instance being created.
      return false if user.import_mode
      # Anonymous-mode shadow accounts are not new members.
      return false if AnonymousUser.exists?(user_id: user.id)

      true
    end

    def record(user)
      return unless genuine_registration?(user)

      event_id =
        EventId.derive(
          event_name: "CompleteRegistration",
          object_type: "user",
          object_id: user.id,
          site: Discourse.current_hostname,
        )

      Discourse.redis.setex(key(user.id), TTL.to_i, event_id)
      event_id
    rescue StandardError => e
      Discourse.warn_exception(e, message: "discourse-meta-pixel: failed to record registration")
      nil
    end

    # Read and remove in one round trip. `getdel` is what makes this
    # exactly-once even when two tabs render simultaneously.
    def consume(user_id)
      return nil if user_id.blank?

      value = Discourse.redis.getdel(key(user_id))
      return nil if value.blank?
      return nil unless EventId.valid?(value)

      value
    rescue StandardError => e
      Discourse.warn_exception(e, message: "discourse-meta-pixel: failed to consume registration")
      nil
    end

    # Beyond Meta's window the event can only be rejected, so it is not worth
    # sending. Checked at consume time as well as bounded by the marker TTL,
    # because a clock skew or a restored Redis snapshot could outlive the TTL.
    def within_event_window?(created_at)
      return false if created_at.blank?

      created_at > MAX_EVENT_AGE.ago
    end
  end
end
