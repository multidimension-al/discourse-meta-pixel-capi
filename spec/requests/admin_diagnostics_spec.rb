# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::AdminDiagnosticsController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
    SiteSetting.meta_pixel_capi_access_token = "super-secret-token"
    SiteSetting.meta_pixel_capi_enabled = true
    DiscourseMetaPixel::Delivery.delete_all
  end

  describe "access control" do
    it "refuses an anonymous caller" do
      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"
      expect(response.status).to eq(404)
    end

    it "refuses a regular user" do
      sign_in(user)
      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"
      expect(response.status).to eq(404)
    end

    it "refuses when the plugin is disabled" do
      SiteSetting.discourse_meta_pixel_enabled = false
      sign_in(admin)

      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"

      expect(response.status).to eq(404)
    end
  end

  describe "#index" do
    before { sign_in(admin) }

    # Diagnostics is the place most likely to leak a credential by accident,
    # so this is asserted directly rather than inferred.
    it "never returns the access token" do
      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"

      expect(response.status).to eq(200)
      expect(response.body).not_to include("super-secret-token")
      expect(response.parsed_body["access_token_configured"]).to eq(true)
      expect(response.parsed_body).not_to have_key("access_token")
    end

    it "reports configuration and delivery state" do
      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"

      json = response.parsed_body
      expect(json["dataset_id"]).to eq("123456789012345")
      expect(json["capi_enabled"]).to eq(true)
      expect(json["graph_api_version"]).to be_present
      expect(json["enabled_events"]).to be_present
    end

    it "warns when the Conversions API has no token" do
      SiteSetting.meta_pixel_capi_enabled = false
      SiteSetting.meta_pixel_capi_access_token = ""
      # Set directly to reach the state the validator refuses to create.
      SiteSetting.provider.save(:meta_pixel_capi_enabled, "t", SiteSettings::TypeSupervisor.types[:bool])
      SiteSetting.refresh!

      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"

      keys = response.parsed_body["warnings"].map { |w| w["key"] }
      expect(keys).to include("capi_without_token")
    end

    it "warns while a test event code is configured" do
      SiteSetting.meta_pixel_test_event_code = "TEST123"

      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"

      keys = response.parsed_body["warnings"].map { |w| w["key"] }
      expect(keys).to include("test_mode_active")
    end

    it "answers a plain non-XHR request with JSON" do
      get "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json",
          headers: {
            "HTTP_ACCEPT" => "*/*",
          }

      expect(response.media_type).to eq("application/json")
    end
  end

  describe "#deliveries" do
    before { sign_in(admin) }

    it "lists rows without exposing matching data" do
      DiscourseMetaPixel::Delivery.create!(
        event_name: "ViewContent",
        event_id: "a" * 32,
        status: :succeeded,
        attempts: 1,
      )

      get "/admin/plugins/discourse-meta-pixel-capi/deliveries.json"

      row = response.parsed_body["deliveries"].first
      expect(row["event_name"]).to eq("ViewContent")
      expect(row["event_id"]).to eq("a" * 32)
      expect(row.keys).to match_array(
        %w[event_name event_id source attempts last_attempted_at last_error status],
      )
    end
  end
end
