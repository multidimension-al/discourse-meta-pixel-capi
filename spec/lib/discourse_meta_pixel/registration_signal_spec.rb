# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::RegistrationSignal do
  fab!(:user)

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    Discourse.redis.del(described_class.key(user.id))
  end

  # `:user_created` is an after-commit hook on every new User row, and plenty of
  # those rows are not signups. Counting them as ad-driven conversions would
  # corrupt the one metric a campaign is optimised against.
  describe ".genuine_registration?" do
    it "accepts an ordinary new account" do
      expect(described_class.genuine_registration?(user)).to eq(true)
    end

    it "rejects a staged user" do
      staged = Fabricate(:user, staged: true)

      expect(described_class.genuine_registration?(staged)).to eq(false)
    end

    it "rejects bots and the system user" do
      expect(described_class.genuine_registration?(Discourse.system_user)).to eq(false)
      expect(described_class.genuine_registration?(Fabricate(:bot))).to eq(false)
    end

    it "rejects a user being created by an import script" do
      imported = Fabricate.build(:user)
      imported.import_mode = true
      imported.save!

      expect(described_class.genuine_registration?(imported)).to eq(false)
    end

    it "rejects an anonymous-mode shadow account" do
      SiteSetting.allow_anonymous_mode = true
      # The shadow is only created for a user who is allowed to go anonymous,
      # which is a trust-level gate, so the master user needs its auto groups.
      master = Fabricate(:user, trust_level: TrustLevel[2], refresh_auto_groups: true)
      shadow = AnonymousShadowCreator.get(master)

      expect(shadow).to be_present
      expect(described_class.genuine_registration?(shadow)).to eq(false)
    end

    it "rejects nil" do
      expect(described_class.genuine_registration?(nil)).to eq(false)
    end
  end

  describe "marker lifecycle" do
    it "stores the deterministic event id for the account" do
      event_id = described_class.record(user)

      expected =
        DiscourseMetaPixel::EventId.derive(
          event_name: "CompleteRegistration",
          object_type: "user",
          object_id: user.id,
          site: Discourse.current_hostname,
        )

      expect(event_id).to eq(expected)
      expect(described_class.consume(user.id)).to eq(expected)
    end

    it "records nothing for a user who is not a genuine registration" do
      staged = Fabricate(:user, staged: true)

      expect(described_class.record(staged)).to be_nil
      expect(described_class.consume(staged.id)).to be_nil
    end

    # Exactly-once is what stops a reload, a second tab or a back navigation
    # turning one registration into several conversions.
    it "can only be consumed once" do
      described_class.record(user)

      expect(described_class.consume(user.id)).to be_present
      expect(described_class.consume(user.id)).to be_nil
    end

    it "expires within Meta's event_time window" do
      described_class.record(user)

      ttl = Discourse.redis.ttl(described_class.key(user.id))
      expect(ttl).to be > 0
      expect(ttl).to be <= described_class::TTL.to_i
    end

    it "refuses a value it did not write" do
      Discourse.redis.setex(described_class.key(user.id), 60, "not-an-event-id")

      expect(described_class.consume(user.id)).to be_nil
    end

    it "returns nothing for a blank user id" do
      expect(described_class.consume(nil)).to be_nil
    end
  end

  describe ".within_event_window?" do
    it "accepts a recent registration" do
      expect(described_class.within_event_window?(1.day.ago)).to eq(true)
    end

    # Meta: "event_time can be up to 7 days before you send an event to Meta."
    it "rejects one past Meta's limit" do
      expect(described_class.within_event_window?(8.days.ago)).to eq(false)
      expect(described_class.within_event_window?(nil)).to eq(false)
    end
  end

  describe "resilience" do
    # The individual commands are stubbed rather than `Discourse.redis` itself:
    # the test harness uses Redis too, so replacing the whole accessor breaks
    # RSpec before the example can assert anything.
    it "never lets a Redis failure interfere with signing up" do
      allow(Discourse.redis).to receive(:setex).and_raise(Redis::CannotConnectError)
      allow(Discourse.redis).to receive(:getdel).and_raise(Redis::CannotConnectError)

      expect { described_class.record(user) }.not_to raise_error
      expect { described_class.consume(user.id) }.not_to raise_error
      expect(described_class.consume(user.id)).to be_nil
    end
  end
end
