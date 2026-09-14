# frozen_string_literal: true

# Standalone tests for the dependency-free parts of the plugin: event identity,
# the event_source_url sanitizer, user_data normalization and hashing, and the
# CAPI client's endpoint construction and error classification.
#
# These run with plain Ruby — no Discourse checkout needed:
#
#   ruby spec/standalone/standalone_test.rb
#
# These are the pieces that decide what leaves the server and where it goes, so
# being able to exercise them anywhere is worth keeping them Rails-free. The
# full RSpec suite covers the Discourse-dependent parts and runs inside a
# Discourse development environment.

require "minitest/autorun"
require_relative "../../lib/discourse_meta_pixel/event_id"
require_relative "../../lib/discourse_meta_pixel/url_sanitizer"
require_relative "../../lib/discourse_meta_pixel/user_data"
require_relative "../../lib/discourse_meta_pixel/capi_client"

class EventIdTest < Minitest::Test
  Id = DiscourseMetaPixel::EventId

  def test_browser_ids_must_be_exactly_32_lowercase_hex
    assert Id.valid_browser_id?("a" * 32)
    assert Id.valid_browser_id?("0123456789abcdef0123456789abcdef")

    refute Id.valid_browser_id?("A" * 32), "upper case"
    refute Id.valid_browser_id?("a" * 31), "too short"
    refute Id.valid_browser_id?("a" * 33), "too long"
    refute Id.valid_browser_id?("g" * 32), "not hex"
    refute Id.valid_browser_id?("")
    refute Id.valid_browser_id?(nil)
    refute Id.valid_browser_id?("../../etc/passwd")
    refute Id.valid_browser_id?("#{"a" * 32}\n")
  end

  # The property the whole deduplication scheme rests on: the same logical
  # event always produces the same id, so a retry or a replayed lifecycle hook
  # cannot become a second conversion.
  def test_derived_ids_are_stable
    args = { event_name: "TopicCreated", object_type: "topic", object_id: 42, site: "forum.example.com" }

    assert_equal Id.derive(**args), Id.derive(**args)
  end

  def test_derived_ids_differ_across_every_input
    base = { event_name: "TopicCreated", object_type: "topic", object_id: 42, site: "a.example" }

    assert_equal 4,
                 [
                   Id.derive(**base),
                   Id.derive(**base.merge(event_name: "ReplyCreated")),
                   Id.derive(**base.merge(object_id: 43)),
                   Id.derive(**base.merge(site: "b.example")),
                 ].uniq.size
  end

  # A first post produces both a TopicCreated (keyed on the topic) and, if the
  # ownership rule were ever broken, a ReplyCreated (keyed on the post). They
  # must not collide even when topic 7 and post 7 both exist.
  def test_object_type_disambiguates_matching_ids
    refute_equal Id.derive(event_name: "X", object_type: "topic", object_id: 7, site: "s"),
                 Id.derive(event_name: "X", object_type: "post", object_id: 7, site: "s")
  end

  def test_derived_ids_are_opaque
    id = Id.derive(event_name: "TopicCreated", object_type: "topic", object_id: 42, site: "s")

    assert_match(/\A[0-9a-f]{64}\z/, id)
    refute_includes id, "42"
    refute_includes id, "TopicCreated"
  end

  def test_derive_rejects_incomplete_input
    assert_raises(ArgumentError) do
      Id.derive(event_name: "", object_type: "topic", object_id: 1, site: "s")
    end
    assert_raises(ArgumentError) do
      Id.derive(event_name: "X", object_type: "topic", object_id: nil, site: "s")
    end
  end
end

class UrlSanitizerTest < Minitest::Test
  S = DiscourseMetaPixel::UrlSanitizer
  BASE = "https://forum.example.com"

  def test_builds_an_absolute_same_site_url
    assert_equal "https://forum.example.com/t/a-topic/12", S.build("/t/a-topic/12", BASE)
  end

  def test_drops_the_fragment
    assert_equal "https://forum.example.com/t/a/1", S.build("/t/a/1#post_5", BASE)
  end

  def test_keeps_only_allowlisted_query_parameters
    assert_equal "https://forum.example.com/latest?page=2&utm_source=news",
                 S.build("/latest?page=2&utm_source=news&secret=x", BASE)
  end

  def test_strips_credential_bearing_parameters
    assert_equal "https://forum.example.com/invites/abc", S.build("/invites/abc?t=tok3n", BASE)
    assert_equal "https://forum.example.com/", S.build("/?state=oauth&code=authcode", BASE)
    assert_equal "https://forum.example.com/search", S.build("/search?q=private+thing", BASE)
  end

  # The security property. A path is the only thing a browser may contribute,
  # and it can never become a different host.
  def test_refuses_anything_that_could_leave_the_site
    refute S.safe_path?("https://evil.example.com/x"), "absolute url"
    refute S.safe_path?("//evil.example.com/x"), "protocol relative"
    refute S.safe_path?("http://evil.example.com"), "scheme"
    refute S.safe_path?("\\\\evil.example.com"), "backslash"
    refute S.safe_path?("/x\\..\\y"), "backslash traversal"
    refute S.safe_path?("../etc/passwd"), "no leading slash"
    refute S.safe_path?("/a/../../etc"), "traversal segment"
    refute S.safe_path?("/x\nSet-Cookie: a=b"), "control character"
    refute S.safe_path?(""), "empty"
    refute S.safe_path?(nil)
    refute S.safe_path?("/#{"a" * 600}"), "over length"
  end

  def test_build_returns_nil_for_an_unsafe_path
    assert_nil S.build("https://evil.example.com/x", BASE)
    assert_nil S.build("//evil.example.com", BASE)
    assert_nil S.build(nil, BASE)
    assert_nil S.build("/ok", "")
    assert_nil S.build("/ok", "ftp://forum.example.com")
  end

  def test_honours_a_subfolder_install
    assert_equal "https://forum.example.com/forum/latest",
                 S.build("/latest", "https://forum.example.com/forum")
  end

  def test_keeps_a_non_default_port
    assert_equal "https://forum.example.com:8443/latest",
                 S.build("/latest", "https://forum.example.com:8443")
  end
end

class UserDataTest < Minitest::Test
  U = DiscourseMetaPixel::UserData

  # Meta: "Trim any leading and trailing spaces. Convert all characters to
  # lowercase." A hash of an un-normalized value matches nobody, which looks
  # like poor match quality rather than a bug.
  def test_email_is_trimmed_and_lowercased_before_hashing
    expected = U.hash_email("person@example.com")

    assert_equal expected, U.hash_email("  Person@Example.COM  ")
    assert_equal expected, U.hash_email("PERSON@EXAMPLE.COM")
  end

  def test_email_hash_is_sha256_hex
    assert_equal Digest::SHA256.hexdigest("person@example.com"), U.hash_email("person@example.com")
    assert_match(/\A[0-9a-f]{64}\z/, U.hash_email("person@example.com"))
  end

  def test_rejects_values_that_are_not_emails
    assert_nil U.hash_email(nil)
    assert_nil U.hash_email("")
    assert_nil U.hash_email("   ")
    assert_nil U.hash_email("not-an-email")
  end

  def test_external_id_is_opaque_and_stable
    id = U.external_id(42, "secret")

    assert_equal id, U.external_id(42, "secret"), "stable"
    refute_equal id, U.external_id(43, "secret"), "distinct per user"
    refute_equal id, U.external_id(42, "other"), "keyed"
    assert_match(/\A[0-9a-f]{64}\z/, id)
  end

  def test_external_id_does_not_carry_the_user_id
    # A long id, so that finding it inside 64 hex characters would mean it was
    # embedded rather than appearing by chance.
    refute_includes U.external_id(9_876_543_210, "secret"), "9876543210"
  end

  # Keyed, not merely hashed: a plain digest of a user id is trivially
  # reversible by enumerating ids, which would make external_id a
  # pseudonymous handle in name only.
  def test_external_id_is_keyed_rather_than_a_plain_digest
    refute_equal Digest::SHA256.hexdigest("meta-external-id:42"),
                 U.external_id(42, "secret")
  end

  def test_external_id_requires_both_inputs
    assert_nil U.external_id(nil, "secret")
    assert_nil U.external_id(42, nil)
    assert_nil U.external_id(42, "")
  end

  def test_build_omits_everything_not_enabled_or_present
    data = U.build(email: "a@b.com", user_id: 1, secret: "s")

    refute data.key?(:em), "email matching is opt in"
    refute data.key?(:external_id), "external id matching is opt in"
    assert_empty data
  end

  def test_build_includes_enabled_matching_signals
    data =
      U.build(
        email: "Person@Example.com",
        user_id: 7,
        secret: "s",
        client_ip_address: "203.0.113.4",
        client_user_agent: "Mozilla/5.0",
        enhanced_email: true,
        external_id_enabled: true,
      )

    assert_equal [Digest::SHA256.hexdigest("person@example.com")], data[:em]
    assert_equal [U.external_id(7, "s")], data[:external_id]
    assert_equal "203.0.113.4", data[:client_ip_address]
    assert_equal "Mozilla/5.0", data[:client_user_agent]
  end

  def test_raw_email_never_appears_in_the_payload
    data = U.build(email: "person@example.com", enhanced_email: true)

    refute_includes data.to_s, "person@example.com"
    refute_includes data.to_s, "@"
  end

  # Meta documents these as "fb.<subdomainIndex>.<creationTime>.<value>" and
  # says they should come from real browser or referral context. A value that
  # is not shaped like one did not come from the Pixel.
  def test_fbp_and_fbc_are_validated_not_trusted
    assert U.valid_fbp?("fb.1.1554763741205.1098115397")
    refute U.valid_fbp?("garbage")
    refute U.valid_fbp?("fb.1.notatime.123")
    refute U.valid_fbp?(nil)

    assert U.valid_fbc?("fb.1.1554763741205.IwAR2F4-dbP0l7Mn1IawQQ")
    refute U.valid_fbc?("IwAR2F4")
    refute U.valid_fbc?("fb.1.1554763741205.#{"a" * 600}")
  end

  def test_build_drops_malformed_cookies
    data = U.build(fbp: "garbage", fbc: "also-garbage")

    refute data.key?(:fbp)
    refute data.key?(:fbc)
  end

  def test_redact_reports_only_key_names
    data = U.build(email: "a@b.com", enhanced_email: true, client_ip_address: "1.2.3.4")

    assert_equal %w[client_ip_address em], U.redact(data)
    refute_includes U.redact(data).to_s, Digest::SHA256.hexdigest("a@b.com")
  end
end

class CapiClientTest < Minitest::Test
  C = DiscourseMetaPixel::CapiClient

  def client(dataset_id: "123456789012345", version: "v26.0", token: "tok")
    C.new(dataset_id: dataset_id, access_token: token, api_version: version)
  end

  def test_endpoint_is_fixed_to_the_graph_host
    assert_equal "https://graph.facebook.com/v26.0/123456789012345/events",
                 client.endpoint.to_s
  end

  # No setting can move this. A configurable outbound endpoint in a component
  # that holds an access token is an SSRF and exfiltration primitive.
  def test_endpoint_rejects_values_that_could_redirect_the_request
    assert_raises(ArgumentError) { client(version: "../../evil").endpoint }
    assert_raises(ArgumentError) { client(version: "v26.0/../..").endpoint }
    assert_raises(ArgumentError) { client(dataset_id: "1/../../evil").endpoint }
    assert_raises(ArgumentError) { client(dataset_id: "evil.com").endpoint }
  end

  def test_configured_requires_all_three
    assert client.configured?
    refute client(token: "").configured?
    refute client(dataset_id: "abc").configured?
    refute client(version: "25").configured?
  end

  def test_test_event_code_is_only_present_when_set
    without = C.new(dataset_id: "123456789012345", access_token: "t", api_version: "v26.0")
    refute without.payload_for([]).key?(:test_event_code)

    blank =
      C.new(dataset_id: "123456789012345", access_token: "t", api_version: "v26.0", test_event_code: "  ")
    refute blank.payload_for([]).key?(:test_event_code)

    with =
      C.new(dataset_id: "123456789012345", access_token: "t", api_version: "v26.0", test_event_code: "TEST123")
    assert_equal "TEST123", with.payload_for([])[:test_event_code]
  end

  def test_the_access_token_travels_in_the_body_not_the_url
    assert_equal "tok", client.payload_for([])[:access_token]
    refute_includes client.endpoint.to_s, "tok"
  end

  # Stands in for Net::HTTPResponse, including header lookup by name.
  FakeResponse =
    Struct.new(:code, :body, :headers) do
      def [](name)
        (headers || {})[name]
      end
    end

  def classify(code, body = "{}", headers = {})
    client.send(:classify, FakeResponse.new(code.to_s, body, headers))
  end

  # A response object with no header support at all must degrade rather than
  # raise: classify runs outside the network rescue.
  HeaderlessResponse = Struct.new(:code, :body)

  def test_a_response_without_headers_does_not_raise
    result = client.send(:classify, HeaderlessResponse.new("429", "{}"))

    assert result.retryable?
    assert_nil result.retry_after
  end

  def test_retry_after_is_read_from_the_header
    assert_equal 120, classify(429, "{}", { "Retry-After" => "120" }).retry_after
    assert_equal 120, classify(429, "{}", { "retry-after" => "120" }).retry_after
    assert_nil classify(429, "{}", { "Retry-After" => "nonsense" }).retry_after
    assert_nil classify(429).retry_after
  end

  def test_retry_after_is_only_read_for_rate_limiting
    assert_nil classify(500, "{}", { "Retry-After" => "120" }).retry_after
  end

  def test_2xx_is_success
    assert classify(200).success?
    assert classify(201).success?
  end

  def test_rate_limiting_and_server_errors_retry
    assert classify(429).retryable?
    assert classify(500).retryable?
    assert classify(502).retryable?
    assert classify(503).retryable?
  end

  def test_documented_transient_graph_codes_retry
    [1, 2, 4, 17, 341, 368, 613].each do |code|
      result = classify(400, { error: { code: code } }.to_json)
      assert result.retryable?, "graph code #{code} should retry"
    end
  end

  # Retrying an expired token or a rejected payload forever is how a queue
  # turns into a backlog nobody looks at.
  def test_permanent_failures_do_not_retry
    [10, 100, 102, 190, 200, 803].each do |code|
      result = classify(400, { error: { code: code } }.to_json)
      assert result.permanent?, "graph code #{code} should be permanent"
    end
  end

  def test_an_unrecognised_4xx_is_permanent
    assert classify(400).permanent?
    assert classify(403).permanent?
  end

  def test_error_message_is_truncated
    long = { error: { code: 100, message: "x" * 500 } }.to_json

    assert_equal 200, classify(400, long).error_message.length
  end

  def test_an_unparseable_body_is_still_classified
    assert classify(500, "<html>gateway</html>").retryable?
    assert classify(400, "not json").permanent?
  end
end
