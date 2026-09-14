# frozen_string_literal: true

require "rails_helper"

# The plugin's only public endpoint. Everything here is a security assertion:
# the schema it accepts is deliberately tiny, and the point of these specs is
# that it cannot be talked into anything wider.
describe DiscourseMetaPixel::EventsController do
  fab!(:user)
  fab!(:category)
  fab!(:private_category) { Fabricate(:private_category, group: Fabricate(:group)) }
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:restricted_topic) { Fabricate(:topic, category: private_category) }
  fab!(:pm) { Fabricate(:private_message_topic) }

  let(:valid_event_id) { "0123456789abcdef0123456789abcdef" }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "test-token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
    DiscourseMetaPixel::BatchBuffer.clear
  end

  # Buffered entries are symbol-keyed at the top level; stringified here so the
  # assertions read the same way they did when this went through Sidekiq args.
  def last_job_args
    DiscourseMetaPixel::BatchBuffer.peek.last&.deep_stringify_keys || {}
  end

  def post_event(params)
    post "/meta-pixel/events.json", params: params
  end

  describe "event name allowlist" do
    it "accepts the four mirrored events" do
      %w[PageView ViewContent Search TopicEngaged].each_with_index do |name, index|
        id = format("%032x", index)
        params = { event_name: name, event_id: id }
        params[:topic_id] = topic.id if %w[ViewContent TopicEngaged].include?(name)

        post_event(params)

        expect(response.status).to eq(200), "#{name} was rejected"
      end
    end

    # The browser must not be able to name an arbitrary Meta event, least of
    # all a conversion the server is supposed to own.
    it "refuses server-authoritative event names" do
      %w[CompleteRegistration TopicCreated ReplyCreated].each do |name|
        post_event(event_name: name, event_id: valid_event_id)

        expect(response.status).to eq(422)
        expect(response.parsed_body["error"]).to eq("unknown_event")
      end
    end

    it "refuses arbitrary event names" do
      ["Purchase", "Lead", "", "../../x", "PageView; DROP TABLE"].each do |name|
        post_event(event_name: name, event_id: valid_event_id)

        expect(response.status).to eq(422)
      end

      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end
  end

  describe "event id validation" do
    it "refuses a malformed event id" do
      [
        "",
        "short",
        "A" * 32,
        "g" * 32,
        "a" * 31,
        "a" * 33,
        "../../etc/passwd",
        "#{"a" * 32}\n",
      ].each do |id|
        post_event(event_name: "PageView", event_id: id)

        expect(response.status).to eq(422), "accepted #{id.inspect}"
        expect(response.parsed_body["error"]).to eq("invalid_event_id")
      end

      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end
  end

  describe "content eligibility" do
    it "refuses ViewContent for a private message" do
      post_event(event_name: "ViewContent", event_id: valid_event_id, topic_id: pm.id)

      expect(response.status).to eq(422)
      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end

    it "refuses ViewContent for a topic anonymous visitors cannot read" do
      post_event(event_name: "ViewContent", event_id: valid_event_id, topic_id: restricted_topic.id)

      expect(response.status).to eq(422)
      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end

    # A signed-in staff member can read a restricted topic, but that does not
    # make the topic public content, and Meta must not learn about it.
    it "refuses a restricted topic even when the caller can see it" do
      sign_in(Fabricate(:admin))

      post_event(event_name: "ViewContent", event_id: valid_event_id, topic_id: restricted_topic.id)

      expect(response.status).to eq(422)
      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end

    it "ignores a topic id for a topic that does not exist" do
      post_event(event_name: "PageView", event_id: valid_event_id, topic_id: 999_999)

      expect(response.status).to eq(200)
      expect(DiscourseMetaPixel::Delivery.last.subject_id).to be_nil
    end

    it "accepts a genuinely public topic" do
      post_event(event_name: "ViewContent", event_id: valid_event_id, topic_id: topic.id)

      expect(response.status).to eq(200)
      expect(DiscourseMetaPixel::Delivery.last.subject_id).to eq(topic.id)
    end
  end

  describe "destination control" do
    # The single most important property of this endpoint: a caller cannot make
    # the plugin report an off-site event_source_url.
    it "cannot be given a URL pointing anywhere but this site" do
      [
        "https://evil.example.com/x",
        "//evil.example.com/x",
        "http://evil.example.com",
        "\\\\evil.example.com",
        "/../../etc/passwd",
        "/x\nSet-Cookie: a=b",
      ].each do |path|
        DiscourseMetaPixel::Delivery.delete_all
        DiscourseMetaPixel::BatchBuffer.clear

        post_event(event_name: "PageView", event_id: valid_event_id, path: path)

        expect(response.status).to eq(200)
        expect(last_job_args["event_source_url"]).to be_nil,
        "#{path.inspect} produced #{last_job_args["event_source_url"].inspect}"
      end
    end

    it "builds a same-site URL from an acceptable path" do
      post_event(event_name: "PageView", event_id: valid_event_id, path: "/latest")

      expect(last_job_args["event_source_url"]).to eq("#{Discourse.base_url}/latest")
    end

    # For a topic the URL comes from the topic record, not from the request at
    # all, so there is nothing to tamper with.
    it "derives a topic URL from the topic rather than the request" do
      post_event(
        event_name: "ViewContent",
        event_id: valid_event_id,
        topic_id: topic.id,
        path: "/somewhere/else",
      )

      expect(last_job_args["event_source_url"]).to include(topic.slug)
    end

    it "strips credential-bearing query parameters from the source URL" do
      post_event(event_name: "PageView", event_id: valid_event_id, path: "/invites/abc?t=secret")

      expect(last_job_args["event_source_url"]).to be_nil, "an invite route is refused outright"
    end

    it "keeps only allowlisted query parameters" do
      post_event(event_name: "PageView", event_id: valid_event_id, path: "/latest?page=2&secret=x")

      expect(last_job_args["event_source_url"]).to eq("#{Discourse.base_url}/latest?page=2")
    end

    it "refuses a sensitive path" do
      post_event(event_name: "PageView", event_id: valid_event_id, path: "/u/alice/messages")

      expect(last_job_args["event_source_url"]).to be_nil
    end
  end

  describe "matching data" do
    # A client cannot assert who it is or where it is coming from.
    it "ignores client-supplied user data entirely" do
      post_event(
        event_name: "PageView",
        event_id: valid_event_id,
        user_data: {
          em: "attacker@example.com",
        },
        client_ip_address: "1.2.3.4",
        client_user_agent: "spoofed",
        fbp: "fb.1.1.1",
        external_id: "someone-else",
      )

      expect(response.status).to eq(200)

      context = last_job_args["request_context"]
      expect(context["client_ip_address"]).not_to eq("1.2.3.4")
      expect(context["client_user_agent"]).not_to eq("spoofed")
      expect(context.to_s).not_to include("attacker@example.com")
      expect(context.to_s).not_to include("someone-else")
    end

    it "derives the IP from the request" do
      post_event(event_name: "PageView", event_id: valid_event_id)

      context = last_job_args["request_context"]
      expect(context["client_ip_address"]).to be_present
    end
  end

  describe "replay protection" do
    it "records a logical event only once" do
      2.times { post_event(event_name: "PageView", event_id: valid_event_id) }

      expect(response.status).to eq(200)
      expect(response.parsed_body["result"]).to eq("duplicate")
      expect(DiscourseMetaPixel::Delivery.count).to eq(1)
    end
  end

  describe "when disabled" do
    it "does nothing when the plugin is off" do
      SiteSetting.discourse_meta_pixel_enabled = false

      post_event(event_name: "PageView", event_id: valid_event_id)

      expect(response.status).to eq(404)
      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
    end

    it "makes no outbound call when the Conversions API is off" do
      SiteSetting.meta_pixel_capi_enabled = false

      post_event(event_name: "PageView", event_id: valid_event_id)

      expect(DiscourseMetaPixel::Delivery.count).to eq(0)
      expect(DiscourseMetaPixel::BatchBuffer.peek).to be_empty
    end
  end

  describe "rate limiting" do
    before { RateLimiter.enable }
    after { RateLimiter.disable }

    it "limits anonymous callers per IP rather than site-wide" do
      stub_const(described_class, "RATE_LIMIT_COUNT", 2) do
        2.times.with_index do |i|
          post_event(event_name: "PageView", event_id: format("%032x", i))
          expect(response.status).to eq(200)
        end

        post_event(event_name: "PageView", event_id: format("%032x", 99))
        expect(response.status).to eq(429)
      end
    end
  end
end
