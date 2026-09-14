# frozen_string_literal: true

require "rails_helper"

# Claiming the row and enqueueing the job are two steps. The claim is what makes
# dispatch idempotent, which means that if the enqueue fails the claim actively
# works against us: every replay is turned away as a duplicate and the
# conversion is lost silently. These specs cover the sweep that closes that gap.
describe Jobs::DiscourseMetaPixel::RecoverDeliveries do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
    DiscourseMetaPixel::BatchBuffer.clear
  end

  def create_delivery(status:, age:, id:, attempts: 0, last_attempted_at: nil, **extra)
    DiscourseMetaPixel::Delivery.create!(
      {
        event_name: "TopicCreated",
        event_id: id,
        status: status,
        attempts: attempts,
        last_attempted_at: last_attempted_at,
        subject_type: "topic",
        subject_id: topic.id,
        created_at: age.ago,
        updated_at: age.ago,
      }.merge(extra),
    )
  end

  def queued
    DiscourseMetaPixel::BatchBuffer.peek.map(&:deep_stringify_keys)
  end

  describe "deliveries whose job never existed" do
    # A healthy job runs within seconds and records an attempt. A pending row
    # with zero attempts and some age behind it had no job: nothing else can
    # produce that state.
    it "re-enqueues a pending delivery that was never picked up" do
      delivery = create_delivery(status: :pending, age: 1.hour, id: "a" * 32)

      described_class.new.execute({})

      expect(queued.size).to eq(1)
      expect(queued.last["event_id"]).to eq("a" * 32)
      expect(delivery.reload).to be_retrying
    end

    it "leaves a freshly enqueued delivery alone" do
      create_delivery(status: :pending, age: 1.minute, id: "b" * 32)

      described_class.new.execute({})

      expect(queued).to be_empty, "a merely slow queue is not a lost job"
    end

    it "leaves a delivery that has actually been attempted alone" do
      create_delivery(status: :pending, age: 1.hour, id: "c" * 32, attempts: 1)

      described_class.new.execute({})

      expect(queued).to be_empty
    end
  end

  describe "deliveries whose job was lost mid-retry" do
    it "re-enqueues one that has gone quiet past the maximum backoff" do
      create_delivery(
        status: :retrying,
        age: 2.days,
        id: "d" * 32,
        attempts: 2,
        last_attempted_at: 12.hours.ago,
      )

      described_class.new.execute({})

      expect(queued.size).to eq(1)
    end

    it "leaves one that is still inside its backoff window alone" do
      create_delivery(
        status: :retrying,
        age: 2.hours,
        id: "e" * 32,
        attempts: 2,
        last_attempted_at: 10.minutes.ago,
      )

      described_class.new.execute({})

      expect(queued).to be_empty
    end
  end

  describe "giving up" do
    # Leaving a row retrying forever would make the diagnostics "retrying"
    # count useless as a signal that something needs attention.
    it "abandons a delivery that has been resurrected too many times" do
      delivery =
        create_delivery(
          status: :retrying,
          age: 5.days,
          id: "f" * 32,
          attempts: described_class::MAX_TOTAL_ATTEMPTS,
          last_attempted_at: 2.days.ago,
        )

      described_class.new.execute({})

      expect(delivery.reload).to be_failed
      expect(delivery.last_error).to eq("recovery_exhausted")
      expect(queued).to be_empty
    end

    # Past Meta's seven-day event_time window a delivery can only be rejected.
    it "abandons a delivery older than Meta's event_time window" do
      delivery = create_delivery(status: :pending, age: 10.days, id: "1" * 32)

      described_class.new.execute({})

      expect(delivery.reload).to be_failed
      expect(delivery.last_error).to eq("event_too_old")
      expect(queued).to be_empty
    end
  end

  describe "scope" do
    it "never touches a succeeded delivery" do
      delivery = create_delivery(status: :succeeded, age: 2.days, id: "2" * 32, attempts: 1)

      described_class.new.execute({})

      expect(delivery.reload).to be_succeeded
      expect(queued).to be_empty
    end

    it "never resurrects a permanently failed delivery" do
      delivery = create_delivery(status: :failed, age: 2.days, id: "3" * 32, attempts: 1)

      described_class.new.execute({})

      expect(delivery.reload).to be_failed
      expect(queued).to be_empty
    end

    it "does nothing when the plugin is disabled" do
      SiteSetting.discourse_meta_pixel_enabled = false
      create_delivery(status: :pending, age: 1.hour, id: "4" * 32)

      described_class.new.execute({})

      expect(queued).to be_empty
    end

    it "does not enqueue when the Conversions API is off, but still tidies" do
      SiteSetting.meta_pixel_capi_enabled = false
      delivery = create_delivery(status: :pending, age: 10.days, id: "5" * 32)

      described_class.new.execute({})

      expect(queued).to be_empty
      expect(delivery.reload).to be_failed, "the too-old sweep still runs"
    end

    it "bounds how much it enqueues in one run" do
      stub_const(described_class, "BATCH_SIZE", 2) do
        3.times { |i| create_delivery(status: :pending, age: 1.hour, id: format("%032x", i)) }

        described_class.new.execute({})

        expect(queued.size).to eq(2)
      end
    end
  end

  describe "the recovered job" do
    # The transient matching data lived in the vanished Sidekiq payload and
    # cannot be recovered. Delivering with weaker matching still beats never
    # delivering.
    it "rebuilds the job from the row's subject reference" do
      create_delivery(status: :pending, age: 1.hour, id: "6" * 32)

      described_class.new.execute({})

      args = queued.last
      expect(args["event_name"]).to eq("TopicCreated")
      expect(args["object_type"]).to eq("topic")
      expect(args["object_id"]).to eq(topic.id)
      expect(args["request_context"]).to be_nil
    end

    # event_time falls back to the subject's own created_at in the job, so a
    # recovered delivery still reports when the thing happened.
    it "leaves event_time to be derived from the subject" do
      create_delivery(status: :pending, age: 1.hour, id: "7" * 32)

      described_class.new.execute({})

      expect(queued.last["event_time"]).to be_nil
    end
  end
end
