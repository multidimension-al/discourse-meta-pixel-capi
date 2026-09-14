# frozen_string_literal: true

require "rails_helper"

# `type: :request` so the bootstrap assertion below can actually issue a GET;
# RSpec infers the type from the directory, and spec/ root is not inferred.
describe "discourse-meta-pixel-capi plugin", type: :request do
  let(:plugin_name) { "discourse-meta-pixel-capi" }

  before do
    SiteSetting.discourse_meta_pixel_enabled = true
    SiteSetting.meta_pixel_capi_access_token = "super-secret-token"
    SiteSetting.meta_pixel_dataset_id = "123456789012345"
  end

  # The most important assertion in this file. If the access token ever became
  # client-visible it would be readable by every visitor, and the failure would
  # be completely silent.
  it "marks the access token as a secret, server-only setting" do
    definition = SiteSetting.all_settings.find { |s| s[:setting].to_s == "meta_pixel_capi_access_token" }

    expect(definition[:secret]).to eq(true)
    expect(SiteSetting.client_settings.map(&:to_s)).not_to include("meta_pixel_capi_access_token")
  end

  it "keeps the access token out of the client site settings payload" do
    payload = SiteSetting.client_settings_json_uncached

    expect(payload).not_to include("super-secret-token")
    expect(payload).not_to include("meta_pixel_capi_access_token")
  end

  it "keeps the access token out of an anonymous page's bootstrap" do
    get "/"

    expect(response.body).not_to include("super-secret-token")
  end

  # Pins the reason this plugin declares no CSP extension: core makes both
  # kinds of declaration a no-op. If either ever changes, this fails and the
  # plugin should start declaring the hosts again.
  it "cannot usefully extend script-src, img-src or connect-src" do
    SiteSetting.discourse_meta_pixel_enabled = true

    builder = ContentSecurityPolicy::Builder.new(base_url: Discourse.base_url)
    builder << {
      script_src: %w[https://connect.facebook.net],
      img_src: %w[https://www.facebook.com],
      connect_src: %w[https://www.facebook.com],
    }
    policy = builder.build

    expect(policy).not_to include("https://connect.facebook.net")
    expect(policy).not_to include("https://www.facebook.com")
    expect(policy).not_to include("img-src")
    expect(policy).not_to include("connect-src")
    expect(ContentSecurityPolicy.policy).to include("strict-dynamic")
  end

  it "registers its settings" do
    expect(SiteSetting.respond_to?(:discourse_meta_pixel_enabled)).to eq(true)
    expect(SiteSetting.respond_to?(:meta_pixel_dataset_id)).to eq(true)
    expect(SiteSetting.respond_to?(:meta_pixel_graph_api_version)).to eq(true)
  end

  # Every event the dispatcher can send must have a setting behind it, which is
  # what makes "an event with no setting cannot be sent" a real guarantee.
  it "has a setting for every dispatchable event" do
    DiscourseMetaPixel::Eligibility::EVENT_SETTINGS.each_value do |setting|
      expect(SiteSetting.respond_to?(setting)).to eq(true), "missing setting #{setting}"
    end

    all_events =
      DiscourseMetaPixel::Eligibility::MIRRORED_EVENTS +
        DiscourseMetaPixel::Eligibility::SERVER_EVENTS
    expect(DiscourseMetaPixel::Eligibility::EVENT_SETTINGS.keys.sort).to eq(all_events.sort)
  end

  # Regression guard for a bug that only a real boot catches.
  #
  # Discourse development builds report a version like "2026.9.0-latest", which
  # RubyGems parses as the prerelease "2026.9.0.pre.latest" and therefore ranks
  # BELOW "2026.9.0". A required_version of "2026.9.0" would refuse to load on
  # the very build this plugin was written against — and the failure is not a
  # quiet skip: the plugin's settings.yml still references its validator
  # classes, so an unactivated plugin takes the whole boot down with
  # "uninitialized constant".
  it "declares a required_version the running Discourse actually satisfies" do
    metadata =
      Plugin::Metadata.parse(File.read(File.expand_path("../plugin.rb", __dir__)))

    expect(metadata.required_version).to be_present
    expect(Gem::Version.new(Discourse::VERSION::STRING)).to be >=
      Gem::Version.new(metadata.required_version)
  end

  # The assertion above is necessary but NOT sufficient, and the gap is exactly
  # how a broken floor shipped: it only proves the floor works against whatever
  # core happens to be checked out here, and this plugin is developed against a
  # newer core than the deployment pins. A floor only misbehaves when core sits
  # on the SAME numeric line as the floor, so a dev checkout one release ahead
  # never reproduces it.
  #
  # TARGETED_RELEASE is the release whose API surface this plugin needs. Core
  # ships that line as prerelease builds off `tests-passed` ("2026.8.0-latest.1"
  # is the commit GBFans pins), and RubyGems reads the hyphen as ".pre.", so
  # 2026.8.0.pre.latest.1 ranks BELOW a bare 2026.8.0. Declaring the targeted
  # release as the floor therefore excludes the targeted release itself, while
  # passing on every later one. The floor has to sit on an earlier line.
  it "declares a required_version that the targeted release's own builds satisfy" do
    metadata =
      Plugin::Metadata.parse(File.read(File.expand_path("../plugin.rb", __dir__)))

    targeted_release = "2026.8.0"
    earliest_build_of_targeted_release = "#{targeted_release}-latest.1"

    expect(Gem::Version.new(earliest_build_of_targeted_release)).to be >=
      Gem::Version.new(metadata.required_version)

    # ...and it is still a real floor, not one lowered into meaninglessness.
    expect(Gem::Version.new("3.4.0")).not_to be >= Gem::Version.new(metadata.required_version)
  end

  it "is actually activated in this environment" do
    plugin = Discourse.plugins_by_name[plugin_name]

    expect(plugin).to be_present
    expect(plugin.enabled?).to eq(true)
  end

  # The settings category is named by a client locale key, and nothing at boot
  # checks that it exists: a missing one renders in the admin UI as
  # "Translation missing: en.admin_js.admin.site_settings.categories.<name>",
  # which is how it shipped the first time. The category name is the top-level
  # key of settings.yml, so the two files have to agree.
  it "names its site settings category in the client locale" do
    settings_category =
      YAML.load_file(File.expand_path("../config/settings.yml", __dir__)).keys.first

    categories =
      YAML.load_file(File.expand_path("../config/locales/client.en.yml", __dir__))
        .dig("en", "admin_js", "admin", "site_settings", "categories")

    expect(categories).to be_present
    expect(categories[settings_category]).to be_present
  end

  # The category key above was one instance of a wider problem: a locale key
  # that is referenced but not defined renders as "Translation missing" in the
  # admin UI and nothing at boot or in any other test notices. This walks every
  # key the plugin's own JavaScript asks for and requires it to resolve.
  #
  # It also rejects non-string keys. Bare `yes:` and `no:` are how this bit the
  # first time: YAML 1.1 reads them as booleans, so the entries parse as the
  # keys true/false and every lookup misses while the file still looks correct.
  it "defines every translation its own JavaScript asks for" do
    root = File.expand_path("..", __dir__)
    client = YAML.load_file(File.join(root, "config/locales/client.en.yml"))

    flat = {}
    walk =
      lambda do |node, path|
        node.each do |key, value|
          expect(key).to be_a(String), "#{(path + [key]).join(".")} is not a string key"

          if value.is_a?(Hash)
            walk.call(value, path + [key])
          else
            flat[(path + [key]).join(".")] = value
          end
        end
      end
    walk.call(client.dig("en", "js"), [])

    referenced =
      Dir[File.join(root, "{admin/assets,assets}/**/*.{js,gjs,hbs}")]
        .flat_map { |file| File.read(file).scan(/"(discourse_meta_pixel\.[A-Za-z0-9_.]+)"/) }
        .flatten
        .uniq

    expect(referenced).not_to be_empty, "the key scan found nothing, so it is not testing anything"
    expect(referenced.reject { |key| flat.key?(key) }).to eq([])
  end
end
