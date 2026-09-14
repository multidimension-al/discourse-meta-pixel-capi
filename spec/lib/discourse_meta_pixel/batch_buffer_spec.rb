# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::BatchBuffer do
  before { described_class.clear }
  after { described_class.clear }

  def entry(id) = { event_name: "ViewContent", event_id: id }

  it "returns the new length so the caller can decide to flush" do
    expect(described_class.push(entry("a"))).to eq(1)
    expect(described_class.push(entry("b"))).to eq(2)
  end

  it "drains in the order things were pushed" do
    %w[a b c].each { |id| described_class.push(entry(id)) }

    expect(described_class.drain(10).map { |e| e[:event_id] }).to eq(%w[a b c])
    expect(described_class.size).to eq(0)
  end

  it "drains no more than asked for" do
    %w[a b c].each { |id| described_class.push(entry(id)) }

    expect(described_class.drain(2).map { |e| e[:event_id] }).to eq(%w[a b])
    expect(described_class.size).to eq(1)
  end

  # `LPOP key count` is atomic, which is what keeps two workers flushing at the
  # same time from taking the same entry.
  it "never hands the same entry to two drains" do
    10.times { |i| described_class.push(entry("e#{i}")) }

    first = described_class.drain(5).map { |e| e[:event_id] }
    second = described_class.drain(5).map { |e| e[:event_id] }

    expect(first & second).to eq([])
    expect((first + second).uniq.length).to eq(10)
  end

  # Age priority matters: an event that misses Meta's deduplication window
  # stops being deduplicated and starts being counted twice.
  it "puts requeued entries back in front of newer ones" do
    described_class.push(entry("old"))
    returned = described_class.drain(1)
    described_class.push(entry("new"))

    described_class.requeue(returned)

    expect(described_class.drain(10).map { |e| e[:event_id] }).to eq(%w[old new])
  end

  it "preserves order within a requeued batch" do
    %w[a b c].each { |id| described_class.push(entry(id)) }
    returned = described_class.drain(3)

    described_class.requeue(returned)

    expect(described_class.drain(10).map { |e| e[:event_id] }).to eq(%w[a b c])
  end

  describe ".oldest_age" do
    it "is nil when the buffer is empty" do
      expect(described_class.oldest_age).to be_nil
    end

    it "reports the age of the entry at the front" do
      described_class.push(entry("a"))

      expect(described_class.oldest_age).to be >= 0
      expect(described_class.oldest_age).to be < 5
    end
  end

  # Past the ceiling the delivery row is left for RecoverDeliveries, which is
  # slower but bounded. Better than a buffer that grows without limit.
  it "refuses to grow past the ceiling" do
    stub_const(described_class, :MAX_ENTRIES, 2) do
      described_class.push(entry("a"))
      described_class.push(entry("b"))

      expect(described_class.push(entry("c"))).to be_nil
      expect(described_class.size).to eq(2)
    end
  end

  it "drops an unreadable entry rather than retrying it forever" do
    Discourse.redis.rpush(described_class::KEY, "not json")
    described_class.push(entry("good"))

    drained = described_class.drain(10)

    expect(drained.map { |e| e[:event_id] }).to eq(%w[good])
  end

  # Buffering is best effort. The delivery row is already claimed, so a Redis
  # outage costs the transient matching data, not the conversion.
  describe "when Redis is unavailable" do
    it "reports a failed push rather than raising" do
      allow(Discourse.redis).to receive(:rpush).and_raise(Redis::CannotConnectError)
      allow(Discourse.redis).to receive(:llen).and_return(0)

      expect { described_class.push(entry("a")) }.not_to raise_error
      expect(described_class.push(entry("a"))).to be_nil
    end

    it "drains empty rather than raising" do
      allow(Discourse.redis).to receive(:lpop).and_raise(Redis::CannotConnectError)

      expect(described_class.drain(10)).to eq([])
    end
  end
end
