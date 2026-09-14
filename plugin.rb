# frozen_string_literal: true

# name: discourse-meta-pixel-capi
# about: Meta Pixel and Conversions API for Discourse, with browser/server event deduplication, background delivery and hard exclusion of private and restricted content.
# meta_topic_id:
# version: 0.1.0
# authors: Multidimension.al
# url: https://github.com/multidimension-al/discourse-meta-pixel-capi
# required_version: 2026.7.0

enabled_site_setting :discourse_meta_pixel_enabled

# Why `required_version` above is 2026.7.0 rather than the 2026.8 API surface
# this plugin actually targets -- and why this note is down here instead of
# beside the field.
#
# 1. It must stay BELOW the running release's own numeric version. Core gates
#    activation on `Gem::Version.new(Discourse::VERSION::STRING) >=
#    Gem::Version.new(required_version)` (lib/version_compatibility.rb), and
#    every build off the `tests-passed` branch carries a PRERELEASE version
#    string -- "2026.8.0-latest.1" at the commit GBFans pins. Gem::Version
#    canonicalises the hyphen to ".pre.", so that parses as
#    2026.8.0.pre.latest.1, which sorts BELOW a bare 2026.8.0. Declaring the
#    version this plugin was written against therefore excludes the exact
#    release it was written against. ".pre" does not rescue it either:
#    2026.8.0.pre.latest.1 < 2026.8.0.pre, because rubygems orders a string
#    segment below the 0 it pads the shorter version with.
#
#    The miss is not a clean skip. `Discourse.activate_plugins!` does not
#    raise -- it prints "Could not activate ..., discourse does not meet
#    required version" to STDERR and moves on -- but `SiteSetting` then loads
#    every `plugins/*/config/settings.yml` straight off the FILESYSTEM,
#    independent of activation, and `TypeSupervisor` constantizes each
#    `validator:` string eagerly. This plugin's settings.yml names validators
#    that only plugin.rb's `require_relative`s define, and those never ran, so
#    boot dies with `NameError: uninitialized constant`.
#
#    So the symptom is an uninitialized-constant crash in a file that looks
#    unrelated, during `db:migrate` in the image build, with the one line that
#    explains it -- "does not meet required version" -- scrolled past far above
#    it in STDERR. A plugin that happened to declare no validator would not
#    crash at all; it would simply not be there, and for this one that would
#    take the Conversions API half with it: a campaign reporting zero
#    conversions rather than an error.
#
#    2026.7.0 still refuses a genuinely old core -- every 3.x release sorts
#    below it -- so this remains a real floor rather than a removed one.
#
# 2. The metadata header must stay an unbroken run of `# key: value` lines
#    with NO bare `#` separator in it. `Plugin::Metadata#parse_line` keeps
#    reading comment lines until the first line of code, and on a line that is
#    only a hash it evaluates `"".split(":")` -> `[]`, destructures nil into
#    `attribute`, and dies on `nil.strip`. A bare `#` in the header does not
#    degrade the metadata, it raises NoMethodError out of plugin discovery.
#    That is why this explanation lives after the first statement, which is
#    what terminates the parse.
#
# spec/plugin_spec.rb pins both halves so neither can rot.

register_asset "stylesheets/admin.scss", :admin

module ::DiscourseMetaPixel
  PLUGIN_NAME = "discourse-meta-pixel-capi"
end

require_relative "lib/discourse_meta_pixel/capi_client"
require_relative "lib/discourse_meta_pixel/validators"
require_relative "config/routes"

# No Content Security Policy declaration, deliberately.
#
# The Pixel loader runs because Discourse's default script-src contains
# 'strict-dynamic': a script created by an already-trusted script (the plugin
# bundle) inherits its trust. The Pixel's own image beacons and network calls
# are unrestricted because the default policy sets no img-src, connect-src or
# default-src at all.
#
# `extend_content_security_policy` was tried and removed, because it is a
# verified no-op in both respects. ContentSecurityPolicy::Builder strips every
# source that does not begin with a quote from script_src — "Strip any sources
# which are ignored under strict-dynamic" — and lists img_src and connect_src
# in TO_BE_EXTENDABLE, whose comment reads "Make extending these directives
# no-op, until core includes them in default CSP". spec/plugin_spec.rb pins
# that behaviour so this comment cannot quietly rot.

add_admin_route "discourse_meta_pixel.admin.title",
                "discourse-meta-pixel-capi",
                use_new_show_route: true

after_initialize do
  require_relative "app/models/discourse_meta_pixel/delivery"
  require_relative "lib/discourse_meta_pixel/event_id"
  require_relative "lib/discourse_meta_pixel/url_sanitizer"
  require_relative "lib/discourse_meta_pixel/user_data"
  require_relative "lib/discourse_meta_pixel/eligibility"
  require_relative "lib/discourse_meta_pixel/registration_signal"
  require_relative "lib/discourse_meta_pixel/event_builder"
  require_relative "lib/discourse_meta_pixel/event_assembler"
  require_relative "lib/discourse_meta_pixel/batch_buffer"
  require_relative "lib/discourse_meta_pixel/throttle"
  require_relative "lib/discourse_meta_pixel/dispatcher"
  require_relative "lib/discourse_meta_pixel/diagnostics"
  require_relative "app/jobs/discourse_meta_pixel/deliver_event"
  require_relative "app/jobs/discourse_meta_pixel/flush_batch"
  require_relative "app/jobs/scheduled/discourse_meta_pixel/purge_deliveries"
  require_relative "app/jobs/scheduled/discourse_meta_pixel/recover_deliveries"
  require_relative "app/jobs/scheduled/discourse_meta_pixel/flush_batches"
  require_relative "app/controllers/discourse_meta_pixel/events_controller"
  require_relative "app/controllers/discourse_meta_pixel/admin_diagnostics_controller"
  require_relative "app/services/problem_check/meta_pixel_capi_credentials"
  require_relative "app/services/problem_check/meta_pixel_test_mode_active"

  register_problem_check ProblemCheck::MetaPixelCapiCredentials
  register_problem_check ProblemCheck::MetaPixelTestModeActive

  # ---------------------------------------------------------------------
  # Excluded groups
  # ---------------------------------------------------------------------
  #
  # The browser half of the exclusion. The server half is enforced inside the
  # dispatcher, on every path, because TopicCreated, ReplyCreated and
  # CompleteRegistration are raised from DiscourseEvent and never involve a
  # browser — see DiscourseMetaPixel::Eligibility.excluded_user?.
  #
  # Resolved here rather than in JavaScript for the same reason as the GA
  # plugin: `currentUser.groups` lists only the groups a user can see, so a
  # hidden group named in the setting would silently never match. Only a
  # boolean crosses to the browser; the chosen group ids stay on the server.
  add_to_serializer(:current_user, :meta_pixel_excluded) do
    next false if !SiteSetting.discourse_meta_pixel_enabled

    DiscourseMetaPixel::Eligibility.excluded_user?(object)
  end

  # ---------------------------------------------------------------------
  # Server-authoritative conversions
  # ---------------------------------------------------------------------
  #
  # Only `post_created` is observed, deliberately.
  #
  # `lib/post_creator.rb#trigger_after_events` fires `:topic_created` and then
  # `:post_created` for the first post of a new topic. Listening to both would
  # make a new topic report as a TopicCreated *and* a ReplyCreated. Taking both
  # events from `post_created` and branching on `post.is_first_post?` puts the
  # decision in one place — `Dispatcher.handle_post_created` — where it can be
  # tested directly.

  on(:post_created) do |post, _opts, _user|
    DiscourseMetaPixel::Dispatcher.handle_post_created(post)
  end

  # Records a marker only. The conversion itself is dispatched on the account's
  # next authenticated render, where there is a real request to draw matching
  # data from and a browser to pair the Pixel copy with. The filter for what
  # counts as a genuine human registration lives in RegistrationSignal.
  on(:user_created) { |user| DiscourseMetaPixel::Dispatcher.handle_user_created(user) }

  # Turns a pending registration marker into a matched browser+server pair.
  #
  # Dispatches the Conversions API half here, where `controller.request` gives
  # the client IP, user agent and the first-party `_fbp` / `_fbc` cookies, then
  # hands the browser the same event id so the Pixel copy deduplicates against
  # it. Only ever rendered for a signed-in user, so the anonymous cache never
  # sees it, and the id is consumed with GETDEL so a reload cannot replay it.
  register_html_builder("server:before-head-close") do |controller|
    next "" unless SiteSetting.discourse_meta_pixel_enabled

    user = controller.respond_to?(:current_user) ? controller.current_user : nil
    next "" if user.blank?

    request = controller.respond_to?(:request) ? controller.request : nil
    next "" if request.blank?

    request_context = {
      client_ip_address: request.remote_ip,
      client_user_agent: request.user_agent.to_s[0, 512],
      fbp: controller.send(:cookies)[:_fbp],
      fbc: controller.send(:cookies)[:_fbc],
    }

    event_id = DiscourseMetaPixel::Dispatcher.consume_registration(user, request_context)
    next "" if event_id.blank?

    "<meta name=\"discourse-meta-pixel-registration\" content=\"#{ERB::Util.html_escape(event_id)}\">"
  end
end
