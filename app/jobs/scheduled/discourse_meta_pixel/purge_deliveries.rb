# frozen_string_literal: true

module Jobs
  module DiscourseMetaPixel
    # Retention for the delivery table.
    #
    # The table exists for idempotency and observability, and neither needs an
    # unbounded history. Without this the `failed` rows in particular would
    # grow forever: a misconfigured access token produces one permanently
    # failed row per event, and nothing would ever remove them.
    #
    # The retention floor matters. Meta deduplicates a browser event against a
    # server event for 48 hours, so a row must outlive that window or the
    # idempotency guarantee is lost while it is still meaningful. The setting
    # has a minimum of 7 days for that reason.
    class PurgeDeliveries < ::Jobs::Scheduled
      every 1.day

      def execute(_args)
        # The setting has a minimum of 7, so there is no "retention disabled"
        # case to guard against — a zero here would mean the setting definition
        # changed, and deleting everything would be the wrong response to that.
        days = SiteSetting.meta_pixel_delivery_retention_days.to_i
        cutoff = days.days.ago

        ::DiscourseMetaPixel::Delivery
          .where(status: ::DiscourseMetaPixel::Delivery.statuses.values_at(:succeeded, :failed))
          .where("created_at < ?", cutoff)
          .in_batches(of: 5_000)
          .delete_all
      end
    end
  end
end
