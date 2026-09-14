# frozen_string_literal: true

module Jobs
  module DiscourseMetaPixel
    # Decides when a partly-filled batch has waited long enough.
    #
    # A full batch is flushed the moment it fills, by the dispatcher. This
    # exists for the rest of the time: a quiet forum that takes an hour to
    # accumulate a hundred events should not hold the first one for an hour.
    #
    # Runs every minute, which is the finest granularity Discourse's scheduler
    # offers and far below the wait window, so the effective delay for any event
    # is the wait window plus at most sixty seconds.
    class FlushBatches < ::Jobs::Scheduled
      every 1.minute

      # A bound on work per run. A backlog is drained over several runs rather
      # than flooding the queue from one.
      MAX_BATCHES_PER_RUN = 20

      def execute(_args)
        return unless ::DiscourseMetaPixel::Dispatcher.enabled?
        return if ::DiscourseMetaPixel::Throttle.throttled?

        batches_due.times { ::Jobs.enqueue(Jobs::DiscourseMetaPixel::FlushBatch) }
      end

      private

      def buffer
        ::DiscourseMetaPixel::BatchBuffer
      end

      # How many flushes to enqueue now.
      #
      # Counted from the buffer's current size rather than looped on it: the
      # flushes run asynchronously, so the buffer has not shrunk by the time
      # this decides, and re-reading it would enqueue the ceiling every run.
      def batches_due
        size = buffer.size
        return 0 if size.zero?

        batch_size = SiteSetting.meta_pixel_batch_size
        full = size / batch_size

        # Nothing full, but the oldest has waited long enough to go alone.
        full = 1 if full.zero? && aged_out?

        [full, MAX_BATCHES_PER_RUN].min
      end

      def aged_out?
        age = buffer.oldest_age
        age.present? && age >= SiteSetting.meta_pixel_batch_max_wait_seconds
      end
    end
  end
end
