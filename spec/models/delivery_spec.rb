# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::Delivery do
  before { described_class.delete_all }

  describe "the idempotency boundary" do
    it "refuses a second row for the same event name and id" do
      described_class.create!(event_name: "PageView", event_id: "a" * 32)

      expect {
        described_class.create!(event_name: "PageView", event_id: "a" * 32)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    # Enforced by the database, not only by the model validation, so a race
    # between two requests cannot slip a duplicate through.
    it "is enforced by a unique index" do
      described_class.create!(event_name: "PageView", event_id: "b" * 32)

      expect {
        described_class.insert_all!(
          [
            {
              event_name: "PageView",
              event_id: "b" * 32,
              status: 0,
              source: 0,
              attempts: 0,
              created_at: Time.zone.now,
              updated_at: Time.zone.now,
            },
          ],
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same id under a different event name" do
      described_class.create!(event_name: "PageView", event_id: "c" * 32)

      expect {
        described_class.create!(event_name: "ViewContent", event_id: "c" * 32)
      }.not_to raise_error
    end
  end

  describe ".claim" do
    it "reports whether it created the row" do
      _, created = described_class.claim(event_name: "PageView", event_id: "d" * 32, source: "browser")
      expect(created).to eq(true)

      record, created_again =
        described_class.claim(event_name: "PageView", event_id: "d" * 32, source: "browser")
      expect(created_again).to eq(false)
      expect(record).to be_present
    end

    it "returns the existing row on a race" do
      described_class.create!(event_name: "PageView", event_id: "e" * 32)

      record, created = described_class.claim(event_name: "PageView", event_id: "e" * 32, source: "browser")

      expect(created).to eq(false)
      expect(record.event_id).to eq("e" * 32)
    end
  end

  describe "#record_attempt!" do
    it "increments attempts and truncates the error" do
      delivery = described_class.create!(event_name: "PageView", event_id: "f" * 32)

      delivery.record_attempt!(status: :retrying, error: "x" * 500)

      expect(delivery.attempts).to eq(1)
      expect(delivery.last_error.length).to eq(120)
      expect(delivery.last_attempted_at).to be_present
    end
  end
end
