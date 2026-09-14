# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module DiscourseMetaPixel
  # The Conversions API client.
  #
  # Owns endpoint construction, authentication, serialization, response
  # handling and error classification. It does not decide *whether* to send
  # anything and it does not retry — retries are the job's business, driven by
  # the classification this returns.
  #
  # ## The endpoint is not configurable
  #
  # The host is a constant and the path is built from a version that must match
  # `vNN.N` and a dataset id that must be digits. There is deliberately no
  # setting for a base URL. A configurable outbound endpoint in a plugin that
  # holds an access token and forwards user matching data is a
  # server-side-request-forgery primitive and a credential exfiltration route;
  # the flexibility is not worth it.
  class CapiClient
    GRAPH_HOST = "graph.facebook.com"

    # Meta supports each Graph API version for at least two years. The setting
    # exists so an administrator can move forward without a plugin release, and
    # is format-validated rather than free text.
    VERSION_PATTERN = /\Av\d{1,3}\.\d{1,2}\z/
    DATASET_PATTERN = /\A\d{5,}\z/

    DEFAULT_TIMEOUT = 10

    # Meta closes idle connections well before this; it only bounds how long a
    # reused socket is trusted between requests in one flush.
    KEEP_ALIVE_TIMEOUT = 30

    # Transport-level outcomes, kept separate from Meta's own error codes so
    # the job has one thing to switch on.
    Result =
      Struct.new(
        :status,
        :http_status,
        :error_code,
        :error_message,
        :fbtrace_id,
        :retry_after,
        keyword_init: true,
      ) do
        def success?
          status == :success
        end

        def retryable?
          status == :retryable
        end

        def permanent?
          status == :permanent
        end
      end

    # Graph API error codes Meta documents as transient. Everything else is
    # treated as permanent, because retrying a rejected payload forever is how
    # a queue turns into a backlog nobody looks at.
    #
    #   1   API Unknown          "Wait and retry the operation."
    #   2   API Service          "Temporary issue due to downtime."
    #   4   API Too Many Calls
    #   17  API User Too Many Calls
    #   341 Application limit reached
    #   368 Temporarily blocked for policies violations
    #   613 Rate limit
    TRANSIENT_ERROR_CODES = [1, 2, 4, 17, 341, 368, 613].freeze

    # 190 is an expired or invalid access token, 100 an invalid parameter, 10
    # a permissions problem. None of those get better by being retried; they
    # need an administrator.
    PERMANENT_ERROR_CODES = [10, 100, 102, 190, 200, 803].freeze

    def initialize(dataset_id:, access_token:, api_version:, test_event_code: nil, timeout: DEFAULT_TIMEOUT)
      @dataset_id = dataset_id.to_s
      @access_token = access_token.to_s
      @api_version = api_version.to_s
      code = test_event_code.to_s.strip
      @test_event_code = code.empty? ? nil : code
      @timeout = timeout
      @http = nil
      @connection_reuse = false
    end

    def configured?
      DATASET_PATTERN.match?(@dataset_id) && VERSION_PATTERN.match?(@api_version) &&
        !@access_token.empty?
    end

    def endpoint
      raise ArgumentError, "invalid dataset id" unless DATASET_PATTERN.match?(@dataset_id)
      raise ArgumentError, "invalid api version" unless VERSION_PATTERN.match?(@api_version)

      URI::HTTPS.build(host: GRAPH_HOST, path: "/#{@api_version}/#{@dataset_id}/events")
    end

    # @param events [Array<Hash>] already-built server events
    # @return [Result]
    def send_events(events)
      unless configured?
        return Result.new(status: :permanent, error_code: nil, error_message: "not_configured")
      end

      post(events)
    end

    # Keep one TLS connection open across several sends.
    #
    # A batch flush normally makes a single request, but a batch Meta rejects
    # is retried event by event to find the one at fault -- and that is
    # precisely when opening a fresh connection per event is most wasteful.
    # Outside the block the client behaves exactly as before, opening and
    # closing per request.
    #
    # The connection is closed however the block exits, and a connection that
    # dies mid-block is simply reopened on the next request.
    def with_connection
      previous = @connection_reuse
      @connection_reuse = true
      yield self
    ensure
      close_connection
      @connection_reuse = previous
    end

    # The access token travels in the body rather than the query string, so it
    # never lands in an intermediary's access log.
    #
    # Meta: "The test_event_code field should be used only for testing. You
    # need to remove it when sending your production payload." It is present
    # only when an administrator has set one.
    def payload_for(events)
      body = { data: events, access_token: @access_token }
      body[:test_event_code] = @test_event_code if @test_event_code
      body
    end

    private

    def post(events)
      uri = endpoint

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = payload_for(events).to_json

      classify(perform(uri, request))
    rescue Net::OpenTimeout,
           Net::ReadTimeout,
           Errno::ECONNREFUSED,
           Errno::ECONNRESET,
           Errno::EHOSTUNREACH,
           Errno::EPIPE,
           IOError,
           SocketError,
           OpenSSL::SSL::SSLError => e
      # A network problem is always worth another attempt. A connection that
      # was being reused may simply have been closed by the far end between
      # requests, so it is dropped rather than reused again.
      close_connection
      Result.new(status: :retryable, error_code: nil, error_message: e.class.name)
    end

    # Inside `with_connection` the socket is held open between requests;
    # outside it, this is the original open-and-close behaviour.
    def perform(uri, request)
      return connection(uri).request(request) if @connection_reuse

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: true,
        open_timeout: @timeout,
        read_timeout: @timeout,
      ) { |http| http.request(request) }
    end

    def connection(uri)
      return @http if @http&.started?

      @http =
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = true
          http.open_timeout = @timeout
          http.read_timeout = @timeout
          http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT
          http.start
        end
    end

    def close_connection
      @http.finish if @http&.started?
    rescue IOError
      # Already closed by the far end; nothing to do.
    ensure
      @http = nil
    end

    def classify(response)
      code = response.code.to_i

      return Result.new(status: :success, http_status: code) if code >= 200 && code < 300

      # Meta says how long to wait when it rate limits. Honouring it keeps
      # every other flush from continuing to hammer a limit already hit.
      retry_after = retry_after_seconds(response) if code == 429

      parsed = parse_error(response.body)
      error_code = parsed[:code]

      status =
        if code == 429 || (code >= 500 && code < 600)
          # Rate limiting and server errors are transient by definition,
          # whatever body accompanies them.
          :retryable
        elsif TRANSIENT_ERROR_CODES.include?(error_code)
          :retryable
        elsif PERMANENT_ERROR_CODES.include?(error_code)
          :permanent
        elsif code >= 400 && code < 500
          # An unrecognised 4xx is a rejected request. Retrying it forever
          # would never succeed.
          :permanent
        else
          :retryable
        end

      Result.new(
        status: status,
        http_status: code,
        error_code: error_code,
        # Meta's message can quote back parts of the payload, so it is
        # truncated here and never stored in full.
        error_message: parsed[:message]&.slice(0, 200),
        fbtrace_id: parsed[:fbtrace_id],
        retry_after: retry_after,
      )
    end

    def retry_after_seconds(response)
      seconds = (response["Retry-After"] || response["retry-after"]).to_i
      seconds.positive? ? seconds : nil
    rescue NameError, TypeError, IndexError
      # Something that is not an HTTP response with headers. The absence of a
      # hint is not a reason to fail the request -- the caller falls back to a
      # default backoff. `classify` is outside `post`'s rescue, so letting this
      # propagate would crash the job rather than degrade it.
      nil
    end

    def parse_error(body)
      json = JSON.parse(body.to_s)
      error = json["error"] || {}
      {
        code: error["code"]&.to_i,
        message: error["message"],
        fbtrace_id: error["fbtrace_id"],
      }
    rescue JSON::ParserError, TypeError
      {}
    end
  end
end
