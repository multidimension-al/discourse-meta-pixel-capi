# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseMetaPixel::PurgeDeliveries do
  before do
    DiscourseMetaPixel::Delivery.delete_all
    SiteSetting.meta_pixel_delivery_retention_days = 30
  end

  def create_delivery(status:, age:, id:)
    DiscourseMetaPixel::Delivery.create!(
      event_name: "PageView",
      event_id: id,
      status: status,
      created_at: age.ago,
      updated_at: age.ago,
    )
  end

  it "removes settled rows past the retention window" do
    create_delivery(status: :succeeded, age: 60.days, id: "a" * 32)
    create_delivery(status: :failed, age: 60.days, id: "b" * 32)

    described_class.new.execute({})

    expect(DiscourseMetaPixel::Delivery.count).to eq(0)
  end

  it "keeps settled rows inside the window" do
    create_delivery(status: :succeeded, age: 5.days, id: "c" * 32)

    described_class.new.execute({})

    expect(DiscourseMetaPixel::Delivery.count).to eq(1)
  end

  # An old pending or retrying row is a symptom, not litter. Deleting it would
  # hide a stuck queue and free its event id for a duplicate.
  it "never removes work that has not settled" do
    create_delivery(status: :pending, age: 90.days, id: "d" * 32)
    create_delivery(status: :retrying, age: 90.days, id: "e" * 32)

    described_class.new.execute({})

    expect(DiscourseMetaPixel::Delivery.count).to eq(2)
  end

  # Retention must outlive Meta's 48 hour deduplication window, or the
  # idempotency guarantee lapses while it still matters.
  it "cannot be set below the deduplication window" do
    expect { SiteSetting.meta_pixel_delivery_retention_days = 1 }.to raise_error(
      Discourse::InvalidParameters,
    )
  end
end
