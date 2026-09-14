# frozen_string_literal: true

require "rails_helper"

describe "Meta Pixel excluded groups" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:member) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:category)

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
    DiscourseMetaPixel::BatchBuffer.clear
  end

  def post_by(user)
    PostCreator.create!(user, title: "A perfectly ordinary topic", raw: "Hello " * 20)
  end

  describe ".excluded_user?" do
    it "excludes the default staff groups and nobody else" do
      expect(SiteSetting.meta_pixel_excluded_groups).to eq("1|2")

      expect(DiscourseMetaPixel::Eligibility.excluded_user?(admin)).to eq(true)
      expect(DiscourseMetaPixel::Eligibility.excluded_user?(moderator)).to eq(true)
      expect(DiscourseMetaPixel::Eligibility.excluded_user?(member)).to eq(false)
    end

    it "accepts a bare id, which is what the dispatch paths hold" do
      expect(DiscourseMetaPixel::Eligibility.excluded_user?(admin.id)).to eq(true)
      expect(DiscourseMetaPixel::Eligibility.excluded_user?(member.id)).to eq(false)
    end

    it "excludes nobody when the setting is cleared" do
      SiteSetting.meta_pixel_excluded_groups = ""

      expect(DiscourseMetaPixel::Eligibility.excluded_user?(admin)).to eq(false)
    end

    # The reason membership is resolved here rather than in the browser.
    it "matches a group the browser could never have seen" do
      hidden =
        Fabricate(
          :group,
          visibility_level: Group.visibility_levels[:owners],
          members_visibility_level: Group.visibility_levels[:owners],
        )
      hidden.add(member)
      SiteSetting.meta_pixel_excluded_groups = hidden.id.to_s

      expect(DiscourseMetaPixel::Eligibility.excluded_user?(member)).to eq(true)
    end

    it "never excludes an anonymous visitor, who has no groups" do
      expect(DiscourseMetaPixel::Eligibility.excluded_user?(nil)).to eq(false)
    end
  end

  # The half a browser-only check would have missed entirely: these are raised
  # from DiscourseEvent and never touch a browser.
  describe "server-authoritative conversions" do
    # Driven through the real `:post_created` hook rather than by calling the
    # dispatcher, so this tests what actually happens on a live site.
    it "sends no TopicCreated for an excluded member" do
      post_by(admin)

      expect(DiscourseMetaPixel::Delivery.where(event_name: "TopicCreated").count).to eq(0)
      expect(DiscourseMetaPixel::BatchBuffer.peek).to be_empty
    end

    it "still sends TopicCreated for everyone else" do
      post_by(member)

      expect(DiscourseMetaPixel::Delivery.where(event_name: "TopicCreated").count).to eq(1)
      expect(DiscourseMetaPixel::BatchBuffer.size).to eq(1)
    end

    it "sends no ReplyCreated for an excluded member" do
      topic = post_by(member).topic
      DiscourseMetaPixel::Delivery.delete_all
      DiscourseMetaPixel::BatchBuffer.clear

      PostCreator.create!(admin, topic_id: topic.id, raw: "A reply " * 20)

      expect(DiscourseMetaPixel::Delivery.where(event_name: "ReplyCreated").count).to eq(0)
      expect(DiscourseMetaPixel::BatchBuffer.peek).to be_empty
    end

    it "still sends ReplyCreated for everyone else" do
      topic = post_by(member).topic
      DiscourseMetaPixel::Delivery.delete_all

      PostCreator.create!(member, topic_id: topic.id, raw: "A reply " * 20)

      expect(DiscourseMetaPixel::Delivery.where(event_name: "ReplyCreated").count).to eq(1)
    end

    it "records no registration marker for an excluded member" do
      # `:user_created` already fired during fabrication, so clear whatever it
      # left and re-run the handler as it would run for someone who was staff
      # at the moment they were created.
      DiscourseMetaPixel::RegistrationSignal.consume(moderator.id)

      expect(DiscourseMetaPixel::Dispatcher.handle_user_created(moderator)).to eq(
        :excluded_user,
      )
      expect(DiscourseMetaPixel::RegistrationSignal.consume(moderator.id)).to be_nil
    end

    it "still records one for everyone else" do
      DiscourseMetaPixel::RegistrationSignal.consume(member.id)

      expect(DiscourseMetaPixel::Dispatcher.handle_user_created(member)).to eq(
        :marker_recorded,
      )
      expect(DiscourseMetaPixel::RegistrationSignal.consume(member.id)).to be_present
    end

    # The setting can change between recording a marker and the render that
    # consumes it, and a marker recorded before the exclusion must not fire.
    it "refuses to consume a marker recorded before the group was excluded" do
      SiteSetting.meta_pixel_excluded_groups = ""
      DiscourseMetaPixel::RegistrationSignal.record(admin)

      SiteSetting.meta_pixel_excluded_groups = "1|2"

      expect(DiscourseMetaPixel::Dispatcher.consume_registration(admin, {})).to be_nil
      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end
  end

  # The endpoint is the trust boundary, not the browser. An excluded member's
  # browser should not post at all, but a stale tab or a crafted request must
  # not get through either.
  describe "the mirror endpoint" do
    it "refuses a browser event for an excluded member" do
      expect(
        DiscourseMetaPixel::Dispatcher.dispatch_browser_event(
          event_name: "ViewContent",
          event_id: "a" * 32,
          request_context: {},
          user_id: admin.id,
        ),
      ).to eq(:excluded_user)

      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end

    it "accepts one for everyone else" do
      expect(
        DiscourseMetaPixel::Dispatcher.dispatch_browser_event(
          event_name: "ViewContent",
          event_id: "b" * 32,
          request_context: {},
          user_id: member.id,
        ),
      ).to eq(:enqueued)
    end
  end

  describe "the browser flag" do
    it "tells the browser to suppress everything at source", type: :request do
      sign_in(admin)
      get "/session/current.json"

      expect(response.parsed_body["current_user"]["meta_pixel_excluded"]).to eq(true)
    end

    it "leaves ordinary members alone", type: :request do
      sign_in(member)
      get "/session/current.json"

      expect(response.parsed_body["current_user"]["meta_pixel_excluded"]).to eq(false)
    end
  end
end
