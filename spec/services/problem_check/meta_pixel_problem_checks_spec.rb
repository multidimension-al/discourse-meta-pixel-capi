# frozen_string_literal: true

require "rails_helper"

# Both of these describe a plugin that looks healthy from the forum while
# collecting nothing usable, which is why they are dashboard warnings rather
# than notes on the plugin's own page.

RSpec.describe ProblemCheck::MetaPixelCapiCredentials do
  subject(:check) { described_class.new }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
    SiteSetting.meta_pixel_capi_enabled = true
  end

  it "is quiet while the plugin is disabled" do
    SiteSetting.discourse_meta_pixel_enabled = false
    SiteSetting.meta_pixel_capi_access_token = ""

    expect(check).to be_chill_about_it
  end

  # Pixel-only is a supported configuration, not a half-finished one.
  it "is quiet while the Conversions API is switched off" do
    SiteSetting.meta_pixel_capi_enabled = false
    SiteSetting.meta_pixel_capi_access_token = ""

    expect(check).to be_chill_about_it
  end

  it "is quiet when both credentials are present" do
    expect(check).to be_chill_about_it
  end

  it "reports the Conversions API enabled without an access token" do
    SiteSetting.meta_pixel_capi_access_token = ""

    expect(check).to have_a_problem.with_priority("high")
  end

  it "reports the Conversions API enabled without a dataset ID" do
    SiteSetting.meta_pixel_dataset_id = ""

    expect(check).to have_a_problem.with_priority("high")
  end
end

RSpec.describe ProblemCheck::MetaPixelTestModeActive do
  subject(:check) { described_class.new }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_test_event_code = ""
  end

  it "is quiet with no test code set" do
    expect(check).to be_chill_about_it
  end

  it "is quiet while the plugin is disabled" do
    SiteSetting.discourse_meta_pixel_enabled = false
    SiteSetting.meta_pixel_test_event_code = "TEST12345"

    expect(check).to be_chill_about_it
  end

  # Low priority on purpose: a test code is correct during setup. It only
  # becomes a problem once someone forgets to clear it.
  it "reports a test code left in place" do
    SiteSetting.meta_pixel_test_event_code = "TEST12345"

    expect(check).to have_a_problem.with_priority("low")
  end
end
