# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseMetaPixel::FlushBatch do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }

  let(:endpoint) { "https://graph.facebook.com/v26.0/123456789012345/events" }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    SiteSetting.meta_pixel_graph_api_version = "v26.0"
    DiscourseMetaPixel::Delivery.delete_all
    DiscourseMetaPixel::BatchBuffer.clear
    DiscourseMetaPixel::Throttle.clear
  end

  after do
    DiscourseMetaPixel::BatchBuffer.clear
    DiscourseMetaPixel::Throttle.clear
  end

  # Claim a row and buffer it, the way the dispatcher does.
  def queue(event_id, event_name: "ViewContent", topic_id: topic.id, event_time: nil)
    DiscourseMetaPixel::Delivery.claim(
      event_name: event_name,
      event_id: event_id,
      source: "browser",
      subject_type: "topic",
      subject_id: topic_id,
    )
    DiscourseMetaPixel::BatchBuffer.push(
      event_name: event_name,
      event_id: event_id,
      object_type: "topic",
      object_id: topic_id,
      event_time: event_time || Time.now.to_i,
      request_context: {},
    )
  end

  def delivery(event_id)
    DiscourseMetaPixel::Delivery.find_by(event_id: event_id)
  end


  describe "batching" do
    it "sends the whole buffer in one request" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")
      3.times { |i| queue("a#{i}" * 16) }

      described_class.new.execute({})

      expect(WebMock).to have_requested(:post, endpoint).once.with { |req|
        JSON.parse(req.body)["data"].length == 3
      }
    end

    it "marks every delivery in a successful batch succeeded" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")
      ids = 3.times.map { |i| "b#{i}" * 16 }
      ids.each { |id| queue(id) }

      described_class.new.execute({})

      ids.each { |id| expect(delivery(id)).to be_succeeded }
      expect(DiscourseMetaPixel::BatchBuffer.size).to eq(0)
    end

    it "sends nothing when the buffer is empty" do
      described_class.new.execute({})

      expect(WebMock).not_to have_requested(:post, endpoint)
    end

    it "takes no more than the configured batch size at once" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")
      SiteSetting.meta_pixel_batch_size = 2
      3.times { |i| queue("c#{i}" * 16) }

      described_class.new.execute({})

      expect(WebMock).to have_requested(:post, endpoint).once.with { |req|
        JSON.parse(req.body)["data"].length == 2
      }
      expect(DiscourseMetaPixel::BatchBuffer.size).to eq(1)
    end
  end

  describe "a transient failure" do
    # The whole batch goes back, because the failure was the request's rather
    # than any one event's. Re-sending one Meta already took is safe: the
    # shared event id is what deduplication matches on.
    it "returns the batch to the buffer and marks the rows retrying" do
      stub_request(:post, endpoint).to_return(status: 503, body: "{}")
      ids = 2.times.map { |i| "d#{i}" * 16 }
      ids.each { |id| queue(id) }

      described_class.new.execute({})

      ids.each { |id| expect(delivery(id)).to be_retrying }
      expect(DiscourseMetaPixel::BatchBuffer.size).to eq(2)
    end

    it "does not lose the request context on the way back" do
      stub_request(:post, endpoint).to_return(status: 503, body: "{}")
      DiscourseMetaPixel::Delivery.claim(
        event_name: "ViewContent",
        event_id: "e" * 32,
        source: "browser",
        subject_type: "topic",
        subject_id: topic.id,
      )
      DiscourseMetaPixel::BatchBuffer.push(
        event_name: "ViewContent",
        event_id: "e" * 32,
        object_type: "topic",
        object_id: topic.id,
        event_time: Time.now.to_i,
        request_context: { client_ip_address: "203.0.113.7" },
      )

      described_class.new.execute({})

      returned = DiscourseMetaPixel::BatchBuffer.drain(10).first
      expect(returned[:request_context]["client_ip_address"]).to eq("203.0.113.7")
    end
  end

  describe "a rejected batch" do
    # Meta accepts or rejects a request as a whole, so one malformed event
    # rejects its healthy neighbours. Marking them all failed would lose them.
    it "retries event by event so only the offender fails" do
      ids = 3.times.map { |i| "f#{i}" * 16 }
      ids.each { |id| queue(id) }

      # The batch is rejected; then two singles succeed and one is rejected.
      stub_request(:post, endpoint)
        .to_return(
          status: 400,
          body: { error: { code: 100, message: "Invalid parameter" } }.to_json,
        )
        .then
        .to_return(status: 200, body: "{}")
        .then
        .to_return(
          status: 400,
          body: { error: { code: 100, message: "Invalid parameter" } }.to_json,
        )
        .then
        .to_return(status: 200, body: "{}")

      described_class.new.execute({})

      statuses = ids.map { |id| delivery(id).status }
      expect(statuses.count("succeeded")).to eq(2)
      expect(statuses.count("failed")).to eq(1)
    end

    it "fails a single-event batch directly, without a second pass" do
      stub_request(:post, endpoint).to_return(
        status: 400,
        body: { error: { code: 190, message: "Invalid OAuth access token" } }.to_json,
      )
      queue("g" * 32)

      described_class.new.execute({})

      expect(delivery("g" * 32)).to be_failed
      expect(WebMock).to have_requested(:post, endpoint).once
    end
  end

  describe "entries that should not be sent at all" do
    it "settles a delivery whose topic is gone, and sends the rest" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")
      queue("h" * 32)
      queue("i" * 32, topic_id: topic.id + 9999)

      described_class.new.execute({})

      expect(delivery("h" * 32)).to be_succeeded
      expect(delivery("i" * 32)).to be_failed
      expect(delivery("i" * 32).last_error).to eq("subject_ineligible")
      expect(WebMock).to have_requested(:post, endpoint).once.with { |req|
        JSON.parse(req.body)["data"].length == 1
      }
    end

    it "settles a delivery past Meta's event_time window" do
      queue("j" * 32, event_time: 8.days.ago.to_i)

      described_class.new.execute({})

      expect(delivery("j" * 32)).to be_failed
      expect(delivery("j" * 32).last_error).to eq("event_too_old")
      expect(WebMock).not_to have_requested(:post, endpoint)
    end

    it "skips a delivery that already succeeded" do
      queue("k" * 32)
      delivery("k" * 32).record_attempt!(status: :succeeded)

      described_class.new.execute({})

      expect(WebMock).not_to have_requested(:post, endpoint)
    end
  end

  describe "rate limiting" do
    # Sidekiq's own backoff is per job, which is not enough: every other flush
    # in the queue would keep hitting the same limit.
    it "stands every flush down after a 429" do
      stub_request(:post, endpoint).to_return(
        status: 429,
        body: "{}",
        headers: { "Retry-After" => "120" },
      )
      queue("m" * 32)

      described_class.new.execute({})

      expect(DiscourseMetaPixel::Throttle).to be_throttled
      expect(DiscourseMetaPixel::Throttle.remaining).to be_within(5).of(120)
    end

    it "leaves the buffer alone while throttled" do
      DiscourseMetaPixel::Throttle.back_off!(60)
      queue("n" * 32)

      described_class.new.execute({})

      expect(WebMock).not_to have_requested(:post, endpoint)
      expect(DiscourseMetaPixel::BatchBuffer.size).to eq(1)
    end

    it "does not throttle on an ordinary transient failure" do
      stub_request(:post, endpoint).to_return(status: 503, body: "{}")
      queue("o" * 32)

      described_class.new.execute({})

      expect(DiscourseMetaPixel::Throttle).not_to be_throttled
    end
  end

  it "sends nothing while the Conversions API is switched off" do
    SiteSetting.meta_pixel_capi_enabled = false
    queue("l" * 32)

    described_class.new.execute({})

    expect(WebMock).not_to have_requested(:post, endpoint)
  end
end
