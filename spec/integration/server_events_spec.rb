# frozen_string_literal: true

require "rails_helper"

# End to end from a real Discourse action to a queued conversion. These are the
# specs that would catch the event-ownership mistake the plugin is designed to
# avoid: core fires :topic_created AND :post_created for a new topic's first
# post, and naively listening to both produces two conversions for one action.
describe "Meta Pixel server-authoritative events" do
  fab!(:category)
  # `refresh_auto_groups: true` is required for the user to be in the automatic
  # trust-level groups; without it `create_topic_allowed_groups` refuses and
  # PostCreator raises InvalidAccess before any plugin code runs.
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
  end

  def event_names
    DiscourseMetaPixel::Delivery.pluck(:event_name)
  end

  describe "creating a topic" do
    it "produces exactly one TopicCreated and no ReplyCreated" do
      PostCreator.create!(user, title: "A brand new public topic", raw: "Hello there, world.", category: category.id)

      expect(event_names).to eq(["TopicCreated"])
    end

    it "produces a ReplyCreated for a subsequent post" do
      result =
        PostCreator.create!(user, title: "A brand new public topic", raw: "Hello there, world.", category: category.id)
      DiscourseMetaPixel::Delivery.delete_all

      PostCreator.create!(
        Fabricate(:user, refresh_auto_groups: true),
        topic_id: result.topic_id,
        raw: "A reply to the topic.",
      )

      expect(event_names).to eq(["ReplyCreated"])
    end

    it "produces nothing for a private message" do
      PostCreator.create!(
        user,
        title: "A private conversation",
        raw: "Just between us, then.",
        archetype: Archetype.private_message,
        target_usernames: Fabricate(:user, refresh_auto_groups: true).username,
      )

      expect(event_names).to be_empty
    end

    it "produces nothing for a topic anonymous visitors cannot read" do
      private_category = Fabricate(:private_category, group: Fabricate(:group))

      PostCreator.create!(
        Fabricate(:admin),
        title: "A staff only topic here",
        raw: "Internal notes about things.",
        category: private_category.id,
      )

      expect(event_names).to be_empty
    end
  end

  # Registration is a two-step flow: :user_created records a marker, and the
  # account's next authenticated render turns it into a matched browser+server
  # pair. See docs/events.md.
  describe "creating a user" do
    it "records a marker rather than queueing immediately" do
      new_user = Fabricate(:user)

      expect(event_names).to be_empty
      expect(DiscourseMetaPixel::RegistrationSignal.consume(new_user.id)).to be_present
    end

    it "produces exactly one CompleteRegistration once the marker is consumed" do
      new_user = Fabricate(:user)

      DiscourseMetaPixel::Dispatcher.consume_registration(new_user, {})

      expect(event_names).to eq(["CompleteRegistration"])
    end

    it "produces one per user, not one per event replay" do
      new_user = Fabricate(:user)
      DiscourseEvent.trigger(:user_created, new_user)
      DiscourseEvent.trigger(:user_created, new_user)

      2.times { DiscourseMetaPixel::Dispatcher.consume_registration(new_user, {}) }

      expect(DiscourseMetaPixel::Delivery.where(event_name: "CompleteRegistration").count).to eq(1)
    end

    it "records nothing for a staged user" do
      staged = Fabricate(:user, staged: true)

      expect(DiscourseMetaPixel::RegistrationSignal.consume(staged.id)).to be_nil
    end
  end

  describe "when disabled" do
    it "queues nothing at all" do
      SiteSetting.discourse_meta_pixel_enabled = false

      new_user = Fabricate(:user)
      PostCreator.create!(
        user,
        title: "Another public topic here",
        raw: "Some content for it.",
        category: category.id,
      )
      DiscourseMetaPixel::Dispatcher.consume_registration(new_user, {})

      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end
  end
end
