# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseMetaPixel::DeliverEvent do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:post) { Fabricate(:post, topic: topic) }
  fab!(:user)

  let(:event_id) { "0123456789abcdef0123456789abcdef" }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
  end

  def claim(event_name: "ViewContent", source: "browser", subject_type: "topic", subject_id: topic.id)
    DiscourseMetaPixel::Delivery.claim(
      event_name: event_name,
      event_id: event_id,
      source: source,
      subject_type: subject_type,
      subject_id: subject_id,
    ).first
  end

  def args(overrides = {})
    {
      event_name: "ViewContent",
      event_id: event_id,
      object_type: "topic",
      object_id: topic.id,
    }.merge(overrides)
  end

  def stub_capi(status:, body: "{}")
    stub_request(:post, %r{https://graph\.facebook\.com/v\d+\.\d+/123456789012345/events}).to_return(
      status: status,
      body: body,
      headers: {
        "Content-Type" => "application/json",
      },
    )
  end

  describe "success" do
    it "marks the delivery succeeded" do
      delivery = claim
      stub_capi(status: 200)

      described_class.new.execute(args)

      expect(delivery.reload).to be_succeeded
      expect(delivery.attempts).to eq(1)
      expect(delivery.last_error).to be_nil
    end

    it "sends the event id it was given, unchanged" do
      claim
      request = stub_capi(status: 200)

      described_class.new.execute(args)

      expect(request).to have_been_requested
      expect(WebMock).to have_requested(:post, %r{graph\.facebook\.com}).with { |req|
        JSON.parse(req.body)["data"].first["event_id"] == event_id
      }
    end

    it "does nothing for a delivery that already succeeded" do
      delivery = claim
      delivery.update!(status: :succeeded)

      described_class.new.execute(args)

      expect(WebMock).not_to have_requested(:post, %r{graph\.facebook\.com})
    end
  end

  describe "retry classification" do
    # Raising is what hands control back to Sidekiq, which is what makes the
    # retry happen at all.
    it "raises on a network failure" do
      claim
      stub_request(:post, %r{graph\.facebook\.com}).to_timeout

      expect { described_class.new.execute(args) }.to raise_error(described_class::DeliveryError)
      expect(DiscourseMetaPixel::Delivery.first.reload).to be_retrying
    end

    it "raises on 429" do
      claim
      stub_capi(status: 429)

      expect { described_class.new.execute(args) }.to raise_error(described_class::DeliveryError)
    end

    it "raises on 5xx" do
      [500, 502, 503].each do |status|
        DiscourseMetaPixel::Delivery.delete_all
        claim
        stub_capi(status: status)

        expect { described_class.new.execute(args) }.to raise_error(described_class::DeliveryError)
      end
    end

    it "raises on a Graph API code Meta documents as transient" do
      claim
      stub_capi(status: 400, body: { error: { code: 2, message: "temporary" } }.to_json)

      expect { described_class.new.execute(args) }.to raise_error(described_class::DeliveryError)
    end

    # Returning rather than raising is what stops the retries.
    it "does not retry an invalid access token" do
      delivery = claim
      stub_capi(status: 400, body: { error: { code: 190, message: "expired" } }.to_json)

      expect { described_class.new.execute(args) }.not_to raise_error

      expect(delivery.reload).to be_failed
      expect(delivery.last_error).to include("190")
    end

    it "does not retry an unrecognised 4xx" do
      delivery = claim
      stub_capi(status: 400, body: "not json")

      expect { described_class.new.execute(args) }.not_to raise_error
      expect(delivery.reload).to be_failed
    end

    it "counts every attempt" do
      delivery = claim
      stub_capi(status: 500)

      2.times do
        expect { described_class.new.execute(args) }.to raise_error(described_class::DeliveryError)
      end

      expect(delivery.reload.attempts).to eq(2)
    end

    it "preserves the event id across retries" do
      claim
      stub_capi(status: 500)

      expect { described_class.new.execute(args) }.to raise_error(described_class::DeliveryError)
      stub_capi(status: 200)
      described_class.new.execute(args)

      expect(WebMock).to have_requested(:post, %r{graph\.facebook\.com}).twice.with { |req|
        JSON.parse(req.body)["data"].first["event_id"] == event_id
      }
    end
  end

  describe "eligibility at delivery time" do
    # The topic could have been deleted or made private between enqueue and
    # delivery. Rebuilding the payload here rather than storing it is what
    # makes that catchable.
    it "sends nothing when the topic is no longer publicly visible" do
      delivery = claim
      topic.update!(category: Fabricate(:private_category, group: Fabricate(:group)))

      described_class.new.execute(args)

      expect(WebMock).not_to have_requested(:post, %r{graph\.facebook\.com})
      expect(delivery.reload).to be_failed
      expect(delivery.last_error).to eq("subject_ineligible")
    end

    it "sends nothing when the subject has been deleted" do
      delivery = claim(subject_id: 999_999)

      described_class.new.execute(args(object_id: 999_999))

      expect(WebMock).not_to have_requested(:post, %r{graph\.facebook\.com})
      expect(delivery.reload).to be_failed
    end

    it "sends nothing when the plugin was disabled after enqueue" do
      delivery = claim
      SiteSetting.discourse_meta_pixel_enabled = false

      described_class.new.execute(args)

      expect(WebMock).not_to have_requested(:post, %r{graph\.facebook\.com})
      expect(delivery.reload.last_error).to eq("plugin_disabled")
    end
  end

  describe "test event code" do
    it "is absent unless configured" do
      claim
      stub_capi(status: 200)

      described_class.new.execute(args)

      expect(WebMock).to have_requested(:post, %r{graph\.facebook\.com}).with { |req|
        !JSON.parse(req.body).key?("test_event_code")
      }
    end

    it "is included when configured" do
      SiteSetting.meta_pixel_test_event_code = "TEST123"
      claim
      stub_capi(status: 200)

      described_class.new.execute(args)

      expect(WebMock).to have_requested(:post, %r{graph\.facebook\.com}).with { |req|
        JSON.parse(req.body)["test_event_code"] == "TEST123"
      }
    end
  end

  describe "matching data" do
    it "hashes the email rather than sending it, when enabled" do
      SiteSetting.meta_pixel_enhanced_email_matching = true
      claim(event_name: "CompleteRegistration", source: "browser", subject_type: "user", subject_id: user.id)
      stub_capi(status: 200)

      described_class.new.execute(
        args(event_name: "CompleteRegistration", object_type: "user", object_id: user.id, user_id: user.id),
      )

      expect(WebMock).to have_requested(:post, %r{graph\.facebook\.com}).with { |req|
        body = req.body
        expected = Digest::SHA256.hexdigest(user.email.strip.downcase)
        body.include?(expected) && !body.include?(user.email)
      }
    end

    it "sends no email at all when enhanced matching is off" do
      SiteSetting.meta_pixel_enhanced_email_matching = false
      claim(event_name: "CompleteRegistration", source: "browser", subject_type: "user", subject_id: user.id)
      stub_capi(status: 200)

      described_class.new.execute(
        args(event_name: "CompleteRegistration", object_type: "user", object_id: user.id, user_id: user.id),
      )

      expect(WebMock).to have_requested(:post, %r{graph\.facebook\.com}).with { |req|
        parsed = JSON.parse(req.body)
        !parsed["data"].first["user_data"].key?("em") && !req.body.include?(user.email)
      }
    end

    it "never writes matching data to the database" do
      SiteSetting.meta_pixel_enhanced_email_matching = true
      delivery =
        claim(event_name: "CompleteRegistration", source: "browser", subject_type: "user", subject_id: user.id)
      stub_capi(status: 200)

      described_class.new.execute(
        args(
          event_name: "CompleteRegistration",
          object_type: "user",
          object_id: user.id,
          user_id: user.id,
          request_context: {
            client_ip_address: "203.0.113.4",
            client_user_agent: "Mozilla/5.0",
            fbp: "fb.1.1554763741205.1098115397",
          },
        ),
      )

      serialized = delivery.reload.attributes.to_s
      expect(serialized).not_to include(user.email)
      expect(serialized).not_to include("203.0.113.4")
      expect(serialized).not_to include("Mozilla/5.0")
      expect(serialized).not_to include("fb.1.1554763741205")
    end
  end

  describe "when the plugin is disabled entirely" do
    it "makes zero outbound calls" do
      SiteSetting.discourse_meta_pixel_enabled = false
      claim

      described_class.new.execute(args)

      expect(WebMock).not_to have_requested(:post, %r{graph\.facebook\.com})
    end
  end

  describe "event_time" do
    # Captures the payloads WebMock saw, so a timestamp can be asserted
    # directly instead of through a matcher side effect.
    def sent_event_times
      WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map do |signature|
        JSON.parse(signature.body)["data"].first["event_time"]
      end
    end

    it "sends the occurrence time it was given, not the time the job ran" do
      claim
      stub_capi(status: 200)
      occurred_at = 3.days.ago.to_i

      described_class.new.execute(args(event_time: occurred_at))

      expect(sent_event_times).to eq([occurred_at])
    end

    # The value travels in the job payload, so Sidekiq replaying the job
    # replays the same timestamp. A drifting event_time across retries would
    # scatter one conversion across different attribution windows.
    it "is identical across retries" do
      claim
      stub_capi(status: 500)
      occurred_at = 2.days.ago.to_i

      expect {
        described_class.new.execute(args(event_time: occurred_at))
      }.to raise_error(described_class::DeliveryError)

      stub_capi(status: 200)
      described_class.new.execute(args(event_time: occurred_at))

      expect(sent_event_times.uniq).to eq([occurred_at])
    end

    # Falling back to the subject's created_at rather than to the clock means a
    # delivery re-enqueued by the recovery sweep still reports when the thing
    # happened.
    it "falls back to the subject's creation time, never to now" do
      claim
      stub_capi(status: 200)

      described_class.new.execute(args.except(:event_time))

      expect(sent_event_times).to eq([topic.created_at.to_i])
    end

    # Past Meta's window the request could only be rejected, and it must stop
    # rather than retry against a deadline it can never meet.
    it "refuses to send an event older than Meta's seven day window" do
      delivery = claim
      stub_capi(status: 200)

      described_class.new.execute(args(event_time: 30.days.ago.to_i))

      expect(WebMock).not_to have_requested(:post, %r{graph\.facebook\.com})
      expect(delivery.reload).to be_failed
      expect(delivery.last_error).to eq("event_too_old")
    end
  end
end
