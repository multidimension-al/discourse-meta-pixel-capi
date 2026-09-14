# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::Dispatcher do
  fab!(:category)
  fab!(:private_category) { Fabricate(:private_category, group: Fabricate(:group)) }
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:user)

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
    DiscourseMetaPixel::BatchBuffer.clear
  end

  def deliveries
    DiscourseMetaPixel::Delivery.all
  end

  # ---------------------------------------------------------------------
  # Event ownership
  # ---------------------------------------------------------------------
  #
  # lib/post_creator.rb fires :topic_created AND then :post_created for the
  # first post of a new topic. This plugin listens only to :post_created and
  # branches here, so the "is this a topic or a reply" decision exists once.
  describe "#handle_post_created" do
    it "reports a first post as TopicCreated, not ReplyCreated" do
      post = Fabricate(:post, topic: topic)
      expect(post.is_first_post?).to eq(true)

      described_class.handle_post_created(post)

      expect(deliveries.pluck(:event_name)).to eq(["TopicCreated"])
    end

    it "reports a subsequent post as ReplyCreated" do
      Fabricate(:post, topic: topic)
      reply = Fabricate(:post, topic: topic)
      DiscourseMetaPixel::Delivery.delete_all

      described_class.handle_post_created(reply)

      expect(deliveries.pluck(:event_name)).to eq(["ReplyCreated"])
    end

    it "never produces both for one post" do
      post = Fabricate(:post, topic: topic)

      described_class.handle_post_created(post)

      expect(deliveries.count).to eq(1)
    end

    it "keys TopicCreated on the topic and ReplyCreated on the post" do
      first = Fabricate(:post, topic: topic)
      reply = Fabricate(:post, topic: topic)

      described_class.handle_post_created(first)
      described_class.handle_post_created(reply)

      topic_delivery = deliveries.find_by(event_name: "TopicCreated")
      reply_delivery = deliveries.find_by(event_name: "ReplyCreated")

      expect(topic_delivery.subject_type).to eq("topic")
      expect(topic_delivery.subject_id).to eq(topic.id)
      expect(reply_delivery.subject_type).to eq("post")
      expect(reply_delivery.subject_id).to eq(reply.id)
    end

    it "sends nothing for a private message" do
      pm = Fabricate(:private_message_topic)
      post = Fabricate(:post, topic: pm)

      described_class.handle_post_created(post)

      expect(deliveries.count).to eq(0)
    end

    it "sends nothing for a topic anonymous visitors cannot read" do
      restricted = Fabricate(:topic, category: private_category)
      post = Fabricate(:post, topic: restricted)

      described_class.handle_post_created(post)

      expect(deliveries.count).to eq(0)
    end
  end

  # ---------------------------------------------------------------------
  # Idempotency
  # ---------------------------------------------------------------------
  describe "deterministic identity" do
    it "produces the same event id every time for the same object" do
      post = Fabricate(:post, topic: topic)

      described_class.handle_post_created(post)
      first_id = deliveries.first.event_id

      DiscourseMetaPixel::Delivery.delete_all
      described_class.handle_post_created(post)

      expect(deliveries.first.event_id).to eq(first_id)
    end

    # Replaying the lifecycle hook is exactly what happens on a re-import, a
    # retried transaction, or a plugin reload. It must not create a second
    # conversion.
    it "does not create a second conversion when the hook is replayed" do
      post = Fabricate(:post, topic: topic)

      results = 3.times.map { described_class.handle_post_created(post) }

      expect(results).to eq(%i[enqueued duplicate duplicate])
      expect(deliveries.count).to eq(1)
      expect(DiscourseMetaPixel::BatchBuffer.size).to eq(1)
    end

    it "does not create a second CompleteRegistration for the same user" do
      described_class.handle_user_created(user)
      2.times { described_class.consume_registration(user, {}) }

      expect(deliveries.where(event_name: "CompleteRegistration").count).to eq(1)
    end

    it "keeps a browser event's id when it is replayed" do
      id = "0123456789abcdef0123456789abcdef"

      first =
        described_class.dispatch_browser_event(
          event_name: "PageView",
          event_id: id,
          request_context: {},
        )
      second =
        described_class.dispatch_browser_event(
          event_name: "PageView",
          event_id: id,
          request_context: {},
        )

      expect(first).to eq(:enqueued)
      expect(second).to eq(:duplicate)
      expect(deliveries.count).to eq(1)
    end
  end

  describe "guards" do
    it "sends nothing when the plugin is disabled" do
      SiteSetting.discourse_meta_pixel_enabled = false

      expect(described_class.handle_user_created(user)).to eq(:disabled)
      expect(deliveries.count).to eq(0)
    end

    it "sends nothing when the Conversions API is off" do
      SiteSetting.meta_pixel_capi_enabled = false

      expect(described_class.handle_user_created(user)).to eq(:disabled)
      expect(DiscourseMetaPixel::BatchBuffer.peek).to be_empty
    end

    it "sends nothing when there is no access token" do
      SiteSetting.meta_pixel_capi_enabled = false
      SiteSetting.meta_pixel_capi_access_token = ""

      expect(described_class.handle_user_created(user)).to eq(:disabled)
    end

    it "respects the per-event setting" do
      SiteSetting.meta_pixel_track_complete_registration = false

      expect(described_class.handle_user_created(user)).to eq(:event_disabled)
      expect(deliveries.count).to eq(0)
    end

    it "refuses a browser event name that is not mirrorable" do
      expect(
        described_class.dispatch_browser_event(
          event_name: "TopicCreated",
          event_id: "0123456789abcdef0123456789abcdef",
          request_context: {},
        ),
      ).to eq(:unknown_event)
    end

    it "refuses a malformed browser event id" do
      expect(
        described_class.dispatch_browser_event(
          event_name: "PageView",
          event_id: "nope",
          request_context: {},
        ),
      ).to eq(:invalid_event_id)
      expect(deliveries.count).to eq(0)
    end

    it "refuses a server event name that is not server-authoritative" do
      expect(
        described_class.dispatch_server_event(
          event_name: "PageView",
          object_type: "topic",
          object_id: 1,
        ),
      ).to eq(:unknown_event)
    end
  end

  # ---------------------------------------------------------------------
  # Occurrence time
  # ---------------------------------------------------------------------
  #
  # Meta uses event_time for attribution and accepts it up to seven days old.
  # Reporting the moment the delivery job happened to run would misattribute
  # every conversion by the length of the queue.
  describe "event_time" do
    def queued_event_time
      DiscourseMetaPixel::BatchBuffer.peek.last[:event_time]
    end

    it "reports when the post was made, not when it was dispatched" do
      post = nil
      freeze_time(3.days.ago) { post = Fabricate(:post, topic: topic) }

      described_class.handle_post_created(post)

      expect(queued_event_time).to eq(post.created_at.to_i)
      expect(queued_event_time).to be < 1.day.ago.to_i
    end

    it "reports the reply's own creation time" do
      Fabricate(:post, topic: topic)
      reply = nil
      freeze_time(2.days.ago) { reply = Fabricate(:post, topic: topic) }
      DiscourseMetaPixel::BatchBuffer.clear

      described_class.handle_post_created(reply)

      expect(queued_event_time).to eq(reply.created_at.to_i)
    end

    it "reports when the account was created, not when the marker was consumed" do
      old_user = nil
      freeze_time(2.days.ago) { old_user = Fabricate(:user) }
      DiscourseMetaPixel::BatchBuffer.clear

      described_class.consume_registration(old_user, {})

      expect(queued_event_time).to eq(old_user.created_at.to_i)
    end

    it "stamps a browser event with the request time" do
      freeze_time do
        described_class.dispatch_browser_event(
          event_name: "PageView",
          event_id: "0123456789abcdef0123456789abcdef",
          request_context: {},
        )

        expect(queued_event_time).to eq(Time.now.to_i)
      end
    end
  end

  # ---------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------
  describe "registration" do
    it "records a marker rather than dispatching immediately" do
      expect(described_class.handle_user_created(user)).to eq(:marker_recorded)

      expect(deliveries.count).to eq(0)
      expect(DiscourseMetaPixel::BatchBuffer.peek).to be_empty
    end

    it "dispatches with request context when the marker is consumed" do
      described_class.handle_user_created(user)

      event_id =
        described_class.consume_registration(
          user,
          { client_ip_address: "203.0.113.4", client_user_agent: "Mozilla/5.0" },
        )

      expect(event_id).to be_present
      expect(deliveries.pluck(:event_name)).to eq(["CompleteRegistration"])

      context = DiscourseMetaPixel::BatchBuffer.peek.last[:request_context]
      expect(context["client_ip_address"]).to eq("203.0.113.4")
      expect(context["client_user_agent"]).to eq("Mozilla/5.0")
    end

    # The shared id is what lets the browser Pixel copy deduplicate against the
    # Conversions API copy.
    it "returns the deterministic id the server used" do
      described_class.handle_user_created(user)
      event_id = described_class.consume_registration(user, {})

      expected =
        DiscourseMetaPixel::EventId.derive(
          event_name: "CompleteRegistration",
          object_type: "user",
          object_id: user.id,
          site: Discourse.current_hostname,
        )

      expect(event_id).to eq(expected)
      expect(deliveries.first.event_id).to eq(expected)
    end

    it "consumes the marker exactly once" do
      described_class.handle_user_created(user)

      first = described_class.consume_registration(user, {})
      second = described_class.consume_registration(user, {})

      expect(first).to be_present
      expect(second).to be_nil
      expect(deliveries.count).to eq(1)
    end

    it "does nothing for a user with no pending marker" do
      expect(described_class.consume_registration(user, {})).to be_nil
      expect(deliveries.count).to eq(0)
    end

    it "drops a registration older than Meta's event_time window" do
      old_user = nil
      freeze_time(30.days.ago) { old_user = Fabricate(:user) }
      DiscourseMetaPixel::RegistrationSignal.record(old_user)

      expect(described_class.consume_registration(old_user, {})).to be_nil
      expect(deliveries.count).to eq(0)
    end
  end
end
