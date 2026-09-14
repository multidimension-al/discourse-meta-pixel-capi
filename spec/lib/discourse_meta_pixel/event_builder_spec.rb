# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::EventBuilder do
  subject(:builder) { described_class.new }

  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category, title: "Which grease for a proton pack") }
  fab!(:user)

  let(:request_context) do
    {
      client_ip_address: "203.0.113.7",
      client_user_agent: "Mozilla/5.0",
      fbp: "fb.1.1700000000000.1234567890",
      fbc: "fb.1.1700000000000.AbCdEf",
    }
  end

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
  end

  def build(**overrides)
    builder.build(
      **{
        event_name: "ViewContent",
        event_id: "a" * 32,
        event_time: 1_700_000_000,
        request_context: request_context,
      }.merge(overrides),
    )
  end

  describe "the event envelope" do
    it "carries exactly the fields Meta requires and no others" do
      event = build

      expect(event[:event_name]).to eq("ViewContent")
      expect(event[:event_id]).to eq("a" * 32)
      expect(event[:event_time]).to eq(1_700_000_000)
      expect(event[:action_source]).to eq("website")
      expect(event).to have_key(:user_data)
    end

    it "omits event_source_url rather than sending a blank one" do
      expect(build).not_to have_key(:event_source_url)
      expect(build(event_source_url: "https://forum.example.com/t/x/1")).to include(
        event_source_url: "https://forum.example.com/t/x/1",
      )
    end

    # event_time is the occurrence time the caller supplies. Rebuilding the
    # same event during a retry must not move it, or Meta re-attributes it.
    it "never invents an event_time when one is given" do
      expect(build(event_time: 1_600_000_000)[:event_time]).to eq(1_600_000_000)
    end
  end

  describe "user_data" do
    it "carries the request signals the server observed" do
      user_data = build[:user_data]

      expect(user_data[:client_ip_address]).to eq("203.0.113.7")
      expect(user_data[:client_user_agent]).to eq("Mozilla/5.0")
      expect(user_data[:fbp]).to eq("fb.1.1700000000000.1234567890")
      expect(user_data[:fbc]).to eq("fb.1.1700000000000.AbCdEf")
    end

    # Meta takes user_data identifiers as arrays, one entry per known value.
    it "sends an opaque external_id rather than the user id" do
      external_id = build(user: user)[:user_data][:external_id]

      expect(external_id).to be_an(Array)
      expect(external_id.first).to match(/\A[0-9a-f]{64}\z/)
      expect(external_id.first).not_to include(user.id.to_s)
    end

    it "withholds external_id when the matching setting is off" do
      SiteSetting.meta_pixel_external_id_matching = false

      expect(build(user: user)[:user_data]).not_to have_key(:external_id)
    end

    # Off by default. Hashed or not, this is the member's email leaving the
    # server, so it stays an explicit opt-in.
    it "sends no email unless enhanced matching is switched on" do
      expect(build(user: user)[:user_data]).not_to have_key(:em)

      SiteSetting.meta_pixel_enhanced_email_matching = true
      expect(build(user: user)[:user_data][:em]).to be_present
    end

    it "never sends a raw email address" do
      SiteSetting.meta_pixel_enhanced_email_matching = true

      em = build(user: user)[:user_data][:em]

      expect(em).to be_an(Array)
      expect(em.first).to match(/\A[0-9a-f]{64}\z/)
      expect(em).not_to include(user.email)
    end
  end

  describe "custom_data" do
    it "is omitted entirely when there is no topic" do
      expect(build).not_to have_key(:custom_data)
    end

    it "describes a public topic by id and category, never by title" do
      custom = build(topic: topic)[:custom_data]

      expect(custom[:content_type]).to eq("topic")
      expect(custom[:content_ids]).to eq([topic.id.to_s])
      expect(custom[:content_category]).to eq(category.slug)
      expect(custom.to_s).not_to include("proton pack")
    end

    it "is omitted for an event that carries no content" do
      expect(build(event_name: "PageView", topic: topic)).not_to have_key(:custom_data)
    end

    # The caller checks visibility first; this repeats it because the whole
    # payload is assembled here and a caller that forgot would otherwise leak
    # a restricted topic's id.
    it "withholds identifiers for a topic that is not publicly visible" do
      restricted = Fabricate(:topic, category: Fabricate(:private_category, group: Fabricate(:group)))

      custom = build(topic: restricted)[:custom_data]

      expect(custom).to eq({ content_type: "topic" })
    end

    it "withholds identifiers for a personal message" do
      pm = Fabricate(:private_message_topic)

      expect(build(topic: pm)[:custom_data]).to eq({ content_type: "topic" })
    end
  end
end
