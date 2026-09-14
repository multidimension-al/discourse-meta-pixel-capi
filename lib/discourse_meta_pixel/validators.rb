# frozen_string_literal: true

module DiscourseMetaPixel
  # A Meta Pixel / dataset id is a numeric string, typically 15-16 digits.
  class DatasetIdValidator
    def initialize(opts = {})
      @opts = opts
    end

    def valid_value?(value)
      return true if value.blank?

      CapiClient::DATASET_PATTERN.match?(value.to_s.strip)
    end

    def error_message
      I18n.t("site_settings.errors.meta_pixel_invalid_dataset_id")
    end
  end

  # The Graph API version, as `vNN.N`.
  #
  # Format-validated rather than free text: the value is interpolated into the
  # request path, so anything else would be both a broken request and an
  # avoidable path-injection surface.
  class GraphApiVersionValidator
    def initialize(opts = {})
      @opts = opts
    end

    def valid_value?(value)
      CapiClient::VERSION_PATTERN.match?(value.to_s.strip)
    end

    def error_message
      I18n.t("site_settings.errors.meta_pixel_invalid_graph_api_version")
    end
  end

  # Refuses to enable the Conversions API without the token it cannot work
  # without, so the failure is at the setting rather than silently in a queue.
  class CapiEnabledValidator
    def initialize(opts = {})
      @opts = opts
    end

    def valid_value?(value)
      return true if value.to_s == "f" || value.to_s == "false" || value == false

      SiteSetting.meta_pixel_capi_access_token.present? &&
        SiteSetting.meta_pixel_dataset_id.present?
    end

    def error_message
      I18n.t("site_settings.errors.meta_pixel_capi_requires_credentials")
    end
  end

  # A Test Events code is a short opaque token from Events Manager.
  class TestEventCodeValidator
    PATTERN = /\A[A-Za-z0-9_-]{1,64}\z/

    def initialize(opts = {})
      @opts = opts
    end

    def valid_value?(value)
      return true if value.blank?

      PATTERN.match?(value.to_s.strip)
    end

    def error_message
      I18n.t("site_settings.errors.meta_pixel_invalid_test_event_code")
    end
  end
end
