# frozen_string_literal: true

# A Test Events code left configured after a verification run.
#
# Events sent with a test code appear in Events Manager's Test Events tab and
# do not count as conversions. Forgetting to clear the code therefore looks
# exactly like a working integration while collecting nothing usable, which is
# why this is a dashboard-level warning rather than a note on the plugin page.
class ProblemCheck::MetaPixelTestModeActive < ProblemCheck
  self.priority = "low"

  def call
    return no_problem if !SiteSetting.discourse_meta_pixel_enabled
    return no_problem if SiteSetting.meta_pixel_test_event_code.blank?

    problem
  end
end
