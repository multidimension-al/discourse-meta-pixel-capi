# frozen_string_literal: true

module DiscourseMetaPixel
  # What an administrator needs to answer "is this working, is it deduplicating,
  # and is anything stuck".
  #
  # Nothing here exposes matching data. The access token is reported as a
  # boolean and never rendered. Delivery rows are reported as counts and short
  # error labels; the `user_data` that was sent is not stored anywhere and so
  # cannot be shown even by mistake.
  module Diagnostics
    module_function

    def access_token_configured?
      SiteSetting.meta_pixel_capi_access_token.present?
    end

    def counts
      Delivery.group(:status).count.transform_keys { |k| Delivery.statuses.key(k) || k.to_s }
    end

    def last_success
      Delivery.succeeded.order(last_attempted_at: :desc).first
    end

    def last_failure
      Delivery.where(status: Delivery.statuses.values_at(:failed, :retrying)).order(
        last_attempted_at: :desc,
      ).first
    end

    def summarize(delivery)
      return nil if delivery.nil?

      {
        event_name: delivery.event_name,
        # The event id is not personal data — it is a random token or a hash of
        # an object reference — and being able to search for it in Events
        # Manager is the whole point of a diagnostics page.
        event_id: delivery.event_id,
        source: delivery.source,
        attempts: delivery.attempts,
        last_attempted_at: delivery.last_attempted_at,
        last_error: delivery.last_error,
      }
    end

    def warnings
      warnings = []

      if SiteSetting.meta_pixel_capi_enabled && !access_token_configured?
        warnings << { key: "capi_without_token", severity: "error" }
      end

      if SiteSetting.meta_pixel_pixel_enabled && SiteSetting.meta_pixel_dataset_id.blank?
        warnings << { key: "pixel_without_id", severity: "error" }
      end

      if SiteSetting.meta_pixel_test_event_code.present?
        # Easy to enable for a verification run and forget. Test events do not
        # count as conversions, so a forgotten code means silently collecting
        # nothing usable.
        warnings << {
          key: "test_mode_active",
          severity: "warning",
          test_event_code: SiteSetting.meta_pixel_test_event_code,
        }
      end

      stuck = Delivery.retrying.where("created_at < ?", 1.day.ago).count
      warnings << { key: "stuck_deliveries", severity: "warning", count: stuck } if stuck > 0

      failed = Delivery.failed.where("created_at > ?", 1.day.ago).count
      warnings << { key: "recent_failures", severity: "warning", count: failed } if failed > 0

      warnings
    end

    def payload
      {
        enabled: SiteSetting.discourse_meta_pixel_enabled,
        pixel_enabled: SiteSetting.meta_pixel_pixel_enabled,
        dataset_id: SiteSetting.meta_pixel_dataset_id,
        capi_enabled: SiteSetting.meta_pixel_capi_enabled,
        # Never the token itself. Whether one exists is all an administrator
        # needs, and all this endpoint will ever say.
        access_token_configured: access_token_configured?,
        graph_api_version: SiteSetting.meta_pixel_graph_api_version,
        test_event_code_configured: SiteSetting.meta_pixel_test_event_code.present?,
        enhanced_email_matching: SiteSetting.meta_pixel_enhanced_email_matching,
        external_id_matching: SiteSetting.meta_pixel_external_id_matching,
        retention_days: SiteSetting.meta_pixel_delivery_retention_days,
        counts: counts,
        last_success: summarize(last_success),
        last_failure: summarize(last_failure),
        enabled_events:
          Eligibility::EVENT_SETTINGS.each_with_object({}) do |(event, setting), memo|
            memo[event] = !!SiteSetting.public_send(setting)
          end,
        warnings: warnings,
      }
    end
  end
end
