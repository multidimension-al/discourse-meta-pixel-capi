# frozen_string_literal: true

Discourse::Application.routes.append do
  # The browser-to-server mirror endpoint.
  #
  # Same-origin, CSRF-protected by Discourse's ordinary AJAX conventions, rate
  # limited, and constrained to a four-event allowlist inside the controller.
  # It is not mounted under /api and there is no API-key path to it.
  post "/meta-pixel/events" => "discourse_meta_pixel/events#create",
       defaults: {
         format: :json,
       }

  # Full-page loads of the plugin's admin page. Core only routes
  # /admin/plugins/:plugin_id and .../settings, so an extra page needs its own
  # Rails route rendering the admin SPA shell; admin/plugins#index does that
  # via check_xhr.
  scope format: false, constraints: ::StaffConstraint.new do
    get "/admin/plugins/discourse-meta-pixel-capi/diagnostics" => "admin/plugins#index"
  end

  # `defaults: { format: :json }` is load-bearing: Admin::AdminController's
  # check_xhr filter would otherwise answer a plain `Accept: */*` request with
  # the admin HTML shell and HTTP 200, before `requires_plugin` ever runs.
  scope "/admin/plugins/discourse-meta-pixel-capi",
        module: "discourse_meta_pixel",
        constraints: ::StaffConstraint.new,
        defaults: {
          format: :json,
        } do
    get "/diagnostics.json" => "admin_diagnostics#index"
    get "/deliveries.json" => "admin_diagnostics#deliveries"
  end
end
