# frozen_string_literal: true

require "uri"

module DiscourseMetaPixel
  # Builds `event_source_url` for a Conversions API event.
  #
  # Two jobs, and the second is the important one:
  #
  # 1. Canonicalise: absolute URL, no fragment, query reduced to an allowlist.
  # 2. Refuse to build a URL that points anywhere but this site.
  #
  # The browser tells the server which path it was on. That input is never
  # trusted as a URL — only as a path, which is then re-attached to this site's
  # own base URL. An attacker who controls the request body cannot make the
  # plugin report an off-site `event_source_url`, and cannot smuggle a
  # credential-bearing query string through to Meta.
  #
  # No Rails dependency, so the rules can be tested exhaustively on their own.
  module UrlSanitizer
    MAX_PATH_LENGTH = 512

    # Query parameters that may survive into `event_source_url`. An allowlist,
    # not a denylist: a forum URL can carry a search term, an invite token, an
    # email-login token or an OAuth `state`, and the next such parameter has
    # not been invented yet.
    ALLOWED_QUERY_PARAMS = %w[
      page
      filter
      order
      ascending
      period
      utm_source
      utm_medium
      utm_campaign
      utm_term
      utm_content
      utm_id
      fbclid
    ].freeze

    module_function

    # Is this a path we are willing to turn into a URL?
    #
    # Rejects anything that could escape the site: a scheme, an authority, a
    # protocol-relative "//host" prefix, a backslash (which some parsers treat
    # as a separator), or a traversal segment.
    def safe_path?(path)
      value = path.to_s

      return false if value.empty?
      return false if value.length > MAX_PATH_LENGTH
      return false unless value.start_with?("/")
      return false if value.start_with?("//")
      return false if value.include?("\\")
      return false if value.include?("://")
      return false if value.match?(/[[:cntrl:]]/)
      return false if value.split("?").first.to_s.split("/").include?("..")

      true
    end

    # Turn a browser-supplied path into an absolute, canonical URL on this site.
    #
    # Returns nil rather than raising for anything unusable; a bad path means
    # the event goes without a source URL, not that a forum request fails.
    def build(path, base_url)
      return nil unless safe_path?(path)
      return nil if base_url.to_s.empty?

      begin
        base = URI.parse(base_url.to_s)
      rescue URI::InvalidURIError
        return nil
      end

      return nil unless %w[http https].include?(base.scheme)

      raw_path, _, raw_query = path.to_s.partition("?")
      raw_path = raw_path.split("#").first.to_s

      canonical = URI::Generic.build(
        scheme: base.scheme,
        host: base.host,
        port: default_port?(base) ? nil : base.port,
        path: join_path(base.path, raw_path),
      )

      query = filtered_query(raw_query)
      canonical.query = query if query

      canonical.to_s
    rescue URI::Error
      nil
    end

    # The authoritative alternative to `build`: when the event is about an
    # object the server already has, take the URL from the object rather than
    # from the request.
    def for_topic(topic, base_url)
      return nil if topic.nil?

      build(topic.relative_url, base_url)
    end

    def default_port?(uri)
      (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
    end

    def join_path(base_path, path)
      prefix = base_path.to_s.chomp("/")
      return path if prefix.empty?
      return prefix if path == "/"

      "#{prefix}#{path}"
    end

    def filtered_query(raw_query)
      return nil if raw_query.to_s.empty?

      pairs =
        raw_query
          .split("&")
          .filter_map do |pair|
            name, _, value = pair.partition("=")
            next unless ALLOWED_QUERY_PARAMS.include?(decode(name))

            "#{name}=#{value}"
          end

      pairs.empty? ? nil : pairs.join("&")
    end

    def decode(value)
      URI.decode_www_form_component(value.to_s)
    rescue ArgumentError
      value.to_s
    end
  end
end
