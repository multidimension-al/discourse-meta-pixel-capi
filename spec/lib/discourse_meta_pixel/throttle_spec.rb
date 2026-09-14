# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::Throttle do
  before { described_class.clear }
  after { described_class.clear }

  it "is not throttled by default" do
    expect(described_class).not_to be_throttled
    expect(described_class.remaining).to eq(0)
  end

  it "stands delivery down for the requested time" do
    described_class.back_off!(30)

    expect(described_class).to be_throttled
    expect(described_class.remaining).to be_within(2).of(30)
  end

  it "falls back to a default when Meta does not say how long" do
    described_class.back_off!(nil)

    expect(described_class.remaining).to be_within(2).of(described_class::DEFAULT_BACKOFF)
  end

  # Two workers hitting the same limit should extend the wait, not race to cut
  # it short.
  it "never shortens a standing deadline" do
    described_class.back_off!(600)
    described_class.back_off!(5)

    expect(described_class.remaining).to be > 300
  end

  it "extends a standing deadline" do
    described_class.back_off!(30)
    described_class.back_off!(600)

    expect(described_class.remaining).to be > 300
  end

  # A malformed or hostile Retry-After must not stand delivery down for longer
  # than Meta's deduplication window tolerates.
  it "caps how long it will wait" do
    described_class.back_off!(99_999_999)

    expect(described_class.remaining).to be <= described_class::MAX_BACKOFF
  end

  it "never blocks delivery when Redis is unavailable" do
    allow(Discourse.redis).to receive(:get).and_raise(Redis::CannotConnectError)

    expect(described_class).not_to be_throttled
  end
end
