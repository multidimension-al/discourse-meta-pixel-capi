# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseMetaPixel::FlushBatches do
  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
    SiteSetting.meta_pixel_batch_size = 3
    SiteSetting.meta_pixel_batch_max_wait_seconds = 300
    DiscourseMetaPixel::BatchBuffer.clear
    Jobs::DiscourseMetaPixel::FlushBatch.jobs.clear
  end

  after { DiscourseMetaPixel::BatchBuffer.clear }

  def buffer(n)
    n.times { |i| DiscourseMetaPixel::BatchBuffer.push(event_name: "PageView", event_id: "x#{i}") }
  end

  def flushes = Jobs::DiscourseMetaPixel::FlushBatch.jobs.size

  it "does nothing on an empty buffer" do
    described_class.new.execute({})

    expect(flushes).to eq(0)
  end

  # A partly-filled batch that is still young waits. The dispatcher flushes a
  # full one immediately, so this job exists for the quiet case.
  it "leaves a short, recent batch alone" do
    buffer(2)

    described_class.new.execute({})

    expect(flushes).to eq(0)
  end

  it "flushes as soon as the buffer reaches the batch size" do
    buffer(3)

    described_class.new.execute({})

    expect(flushes).to be > 0
  end

  # The reason this job exists: a quiet forum should not hold its first event
  # until a hundredth one arrives.
  it "flushes a short batch once it has waited long enough" do
    buffer(1)
    allow(DiscourseMetaPixel::BatchBuffer).to receive(:oldest_age).and_return(301)

    described_class.new.execute({})

    expect(flushes).to eq(1)
  end

  it "does not flush a short batch that has not waited long enough" do
    buffer(1)
    allow(DiscourseMetaPixel::BatchBuffer).to receive(:oldest_age).and_return(299)

    described_class.new.execute({})

    expect(flushes).to eq(0)
  end

  # A backlog is drained over several runs rather than flooding the queue.
  it "enqueues no more than its per-run ceiling" do
    buffer(3)
    allow(DiscourseMetaPixel::BatchBuffer).to receive(:size).and_return(1_000_000)

    described_class.new.execute({})

    expect(flushes).to eq(described_class::MAX_BATCHES_PER_RUN)
  end

  it "does nothing while the Conversions API is switched off" do
    SiteSetting.meta_pixel_capi_enabled = false
    buffer(10)

    described_class.new.execute({})

    expect(flushes).to eq(0)
  end
end
