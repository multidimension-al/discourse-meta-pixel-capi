# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::Eligibility do
  fab!(:category)
  fab!(:group)
  fab!(:private_category) { Fabricate(:private_category, group: group) }

  describe ".publicly_visible_topic?" do
    it "accepts a topic in a public category" do
      expect(described_class.publicly_visible_topic?(Fabricate(:topic, category: category))).to eq(true)
    end

    it "refuses a private message" do
      expect(described_class.publicly_visible_topic?(Fabricate(:private_message_topic))).to eq(false)
    end

    it "refuses a topic in a read-restricted category" do
      topic = Fabricate(:topic, category: private_category)

      expect(described_class.publicly_visible_topic?(topic)).to eq(false)
    end

    it "refuses everything on a login-required forum" do
      SiteSetting.login_required = true
      topic = Fabricate(:topic, category: category)

      expect(described_class.publicly_visible_topic?(topic)).to eq(false)
    end

    it "refuses a deleted topic" do
      topic = Fabricate(:topic, category: category)
      topic.trash!

      expect(described_class.publicly_visible_topic?(topic.reload)).to eq(false)
    end

    it "refuses nil" do
      expect(described_class.publicly_visible_topic?(nil)).to eq(false)
    end

    # The question is "could a logged-out visitor read this", not "can the
    # current request read this". A staff member reading a staff topic does
    # not make it public content.
    it "does not depend on who is asking" do
      topic = Fabricate(:topic, category: private_category)
      admin = Fabricate(:admin)

      expect(Guardian.new(admin).can_see_topic?(topic)).to eq(true)
      expect(described_class.publicly_visible_topic?(topic)).to eq(false)
    end

    it "fails closed when the permission check raises" do
      topic = Fabricate(:topic, category: category)
      allow(Guardian).to receive(:new).and_raise(StandardError)

      expect(described_class.publicly_visible_topic?(topic)).to eq(false)
    end
  end

  describe ".publicly_visible_post?" do
    it "follows the post's topic" do
      public_post = Fabricate(:post, topic: Fabricate(:topic, category: category))
      pm_post = Fabricate(:post, topic: Fabricate(:private_message_topic))

      expect(described_class.publicly_visible_post?(public_post)).to eq(true)
      expect(described_class.publicly_visible_post?(pm_post)).to eq(false)
      expect(described_class.publicly_visible_post?(nil)).to eq(false)
    end
  end

  describe ".sensitive_path?" do
    it "refuses admin, moderation, message and credential routes" do
      %w[
        /admin
        /admin/users/1/alice
        /review
        /safe-mode
        /my/messages
        /u/alice/messages
        /u/alice/preferences/security
        /topics/private-messages/alice
        /u/password-reset/tok
        /u/email-login/tok
        /u/activate-account/tok
        /u/confirm-new-email/tok
        /invites/tok
        /associate/tok
        /auth/facebook/callback
      ].each { |path| expect(described_class.sensitive_path?(path)).to eq(true), "allowed #{path}" }
    end

    it "allows ordinary forum routes" do
      %w[/latest /t/a-topic/12 /c/reviews/12 /tags/c/admin /u/alice /u/alice/summary].each do |path|
        expect(described_class.sensitive_path?(path)).to eq(false), "refused #{path}"
      end
    end

    it "ignores the query string" do
      expect(described_class.sensitive_path?("/latest?next=/admin")).to eq(false)
      expect(described_class.sensitive_path?("/admin?x=1")).to eq(true)
    end
  end

  describe "event allowlists" do
    it "keeps browser-mirrorable and server-only events disjoint" do
      expect(described_class::MIRRORED_EVENTS & described_class::SERVER_EVENTS).to be_empty
    end

    it "refuses an event with no setting behind it" do
      expect(described_class.event_enabled?("Purchase")).to eq(false)
      expect(described_class.event_enabled?(nil)).to eq(false)
    end
  end
end
