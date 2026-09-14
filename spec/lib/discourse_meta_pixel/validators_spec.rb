# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::DatasetIdValidator do
  subject(:validator) { described_class.new }

  it "accepts a Meta dataset id" do
    expect(validator.valid_value?("123456789012345")).to eq(true)
    expect(validator.valid_value?("  123456789012345  ")).to eq(true)
  end

  # Blank is how the setting ships and how it is cleared.
  it "accepts blank" do
    expect(validator.valid_value?("")).to eq(true)
    expect(validator.valid_value?(nil)).to eq(true)
  end

  it "refuses anything that is not a plain numeric id" do
    ["G-ABCD1234", "abc", "123-456", "1234567890123 4", "123", "12345678901234a"].each do |bad|
      expect(validator.valid_value?(bad)).to eq(false), "accepted #{bad.inspect}"
    end
  end

  # No upper bound on purpose. Meta issues these and can lengthen them; a
  # plugin that guessed a maximum would start refusing valid ids, which is a
  # worse failure than passing a too-long one through for Meta to reject.
  it "does not second-guess the length Meta issues" do
    expect(validator.valid_value?("1" * 24)).to eq(true)
  end

  it "has a translated error message" do
    expect(validator.error_message).to be_present
    expect(validator.error_message).not_to include("translation missing")
  end
end

describe DiscourseMetaPixel::GraphApiVersionValidator do
  subject(:validator) { described_class.new }

  it "accepts a Graph API version" do
    expect(validator.valid_value?("v26.0")).to eq(true)
    expect(validator.valid_value?("v9.0")).to eq(true)
  end

  # The value is interpolated into the request path, so a traversal attempt
  # has to be refused at the setting rather than sanitised later.
  it "refuses anything that could alter the request path" do
    ["", "26.0", "v26", "../v26.0", "v26.0/../../me", "v26.0?x=1", "latest"].each do |bad|
      expect(validator.valid_value?(bad)).to eq(false), "accepted #{bad.inspect}"
    end
  end

  it "has a translated error message" do
    expect(validator.error_message).to be_present
    expect(validator.error_message).not_to include("translation missing")
  end
end

describe DiscourseMetaPixel::CapiEnabledValidator do
  subject(:validator) { described_class.new }

  before do
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "token"
  end

  it "allows the Conversions API on when both credentials are present" do
    expect(validator.valid_value?("t")).to eq(true)
  end

  # Turning it off must never be blocked -- that is the way out of a bad state.
  it "always allows turning it off" do
    SiteSetting.meta_pixel_capi_access_token = ""

    expect(validator.valid_value?("f")).to eq(true)
    expect(validator.valid_value?(false)).to eq(true)
  end

  it "refuses to enable it without an access token" do
    SiteSetting.meta_pixel_capi_access_token = ""

    expect(validator.valid_value?("t")).to eq(false)
  end

  it "refuses to enable it without a dataset id" do
    SiteSetting.meta_pixel_dataset_id = ""

    expect(validator.valid_value?("t")).to eq(false)
  end

  it "has a translated error message" do
    expect(validator.error_message).to be_present
    expect(validator.error_message).not_to include("translation missing")
  end
end

describe DiscourseMetaPixel::TestEventCodeValidator do
  subject(:validator) { described_class.new }

  it "accepts a Test Events code" do
    expect(validator.valid_value?("TEST12345")).to eq(true)
    expect(validator.valid_value?("test_code-1")).to eq(true)
  end

  # Blank is the normal state; a code is only set while verifying.
  it "accepts blank" do
    expect(validator.valid_value?("")).to eq(true)
    expect(validator.valid_value?(nil)).to eq(true)
  end

  it "refuses anything that is not a short opaque token" do
    ["has space", "a" * 65, "code;drop", "<script>"].each do |bad|
      expect(validator.valid_value?(bad)).to eq(false), "accepted #{bad.inspect}"
    end
  end

  it "has a translated error message" do
    expect(validator.error_message).to be_present
    expect(validator.error_message).not_to include("translation missing")
  end
end
