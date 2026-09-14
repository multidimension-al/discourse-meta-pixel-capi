# frozen_string_literal: true

# The Conversions API switched on without a usable access token.
#
# Delivery is asynchronous, so this failure is invisible from the forum: posting
# and registering keep working, every conversion is queued, and every one of
# them fails permanently in the background. Surfacing it on the dashboard is the
# only place an administrator would notice.
class ProblemCheck::MetaPixelCapiCredentials < ProblemCheck
  self.priority = "high"

  def call
    return no_problem if !SiteSetting.discourse_meta_pixel_enabled
    return no_problem if !SiteSetting.meta_pixel_capi_enabled
    return no_problem if DiscourseMetaPixel::Diagnostics.access_token_configured? &&
      SiteSetting.meta_pixel_dataset_id.present?

    problem
  end
end
