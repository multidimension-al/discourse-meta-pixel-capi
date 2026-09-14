# frozen_string_literal: true

require "rails_helper"

describe DiscourseMetaPixel::CapiClient do
  subject(:client) do
    described_class.new(
      dataset_id: "123456789012345",
      access_token: "s3cret-token",
      api_version: "v26.0",
    )
  end

  let(:endpoint) { "https://graph.facebook.com/v26.0/123456789012345/events" }

  describe "the endpoint" do
    it "is built from the dataset id and version" do
      expect(client.endpoint.to_s).to eq(endpoint)
    end

    # The host is a constant and both path segments are format-validated. A
    # configurable endpoint in something holding an access token is an SSRF and
    # credential-exfiltration primitive.
    it "refuses a dataset id or version that could alter the path" do
      %w[../me 123/../../me].each do |bad|
        bad_client =
          described_class.new(dataset_id: bad, access_token: "t", api_version: "v26.0")
        expect { bad_client.endpoint }.to raise_error(ArgumentError)
      end

      bad_version =
        described_class.new(dataset_id: "123456789012345", access_token: "t", api_version: "../v1")
      expect { bad_version.endpoint }.to raise_error(ArgumentError)
    end
  end

  describe "the payload" do
    # In the body, never the query string, so it cannot land in an
    # intermediary's access log.
    it "carries the access token in the body" do
      expect(client.payload_for([])[:access_token]).to eq("s3cret-token")
      expect(client.endpoint.to_s).not_to include("s3cret-token")
    end

    it "omits test_event_code unless one is configured" do
      expect(client.payload_for([])).not_to have_key(:test_event_code)

      with_code =
        described_class.new(
          dataset_id: "123456789012345",
          access_token: "t",
          api_version: "v26.0",
          test_event_code: "TEST123",
        )
      expect(with_code.payload_for([])[:test_event_code]).to eq("TEST123")
    end

    it "sends every event it is given in one data array" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")

      client.send_events([{ event_name: "PageView" }, { event_name: "ViewContent" }])

      expect(WebMock).to have_requested(:post, endpoint).with { |req|
        JSON.parse(req.body)["data"].length == 2
      }
    end
  end

  describe "classification" do
    it "treats 2xx as success" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")

      expect(client.send_events([{}])).to be_success
    end

    it "treats rate limiting and server errors as retryable whatever the body" do
      [429, 500, 503].each do |code|
        stub_request(:post, endpoint).to_return(status: code, body: "not json")

        expect(client.send_events([{}])).to be_retryable, "#{code} was not retryable"
      end
    end

    # 190 is an expired or invalid token. Retrying that forever is how a queue
    # becomes a backlog nobody looks at; it needs an administrator.
    it "treats a bad token as permanent" do
      stub_request(:post, endpoint).to_return(
        status: 400,
        body: { error: { code: 190, message: "Invalid OAuth access token" } }.to_json,
      )

      result = client.send_events([{}])

      expect(result).to be_permanent
      expect(result.error_code).to eq(190)
    end

    it "treats a documented transient Graph code as retryable" do
      stub_request(:post, endpoint).to_return(
        status: 400,
        body: { error: { code: 2, message: "Temporary issue due to downtime" } }.to_json,
      )

      expect(client.send_events([{}])).to be_retryable
    end

    it "treats an unrecognised 4xx as permanent" do
      stub_request(:post, endpoint).to_return(status: 422, body: "{}")

      expect(client.send_events([{}])).to be_permanent
    end

    # Meta's message can quote the payload back, and it is shown to admins.
    it "truncates the provider message" do
      stub_request(:post, endpoint).to_return(
        status: 400,
        body: { error: { code: 100, message: "x" * 500 } }.to_json,
      )

      expect(client.send_events([{}]).error_message.length).to eq(200)
    end

    it "reports a network failure as retryable rather than raising" do
      stub_request(:post, endpoint).to_raise(Errno::ECONNRESET)

      expect(client.send_events([{}])).to be_retryable
    end
  end

  it "refuses to send when it is not configured" do
    unconfigured = described_class.new(dataset_id: "", access_token: "", api_version: "v26.0")

    result = unconfigured.send_events([{}])

    expect(result).to be_permanent
    expect(result.error_message).to eq("not_configured")
  end
end
describe DiscourseMetaPixel::CapiClient, "connection reuse" do
  subject(:client) do
    described_class.new(
      dataset_id: "123456789012345",
      access_token: "token",
      api_version: "v26.0",
    )
  end

  let(:endpoint) { "https://graph.facebook.com/v26.0/123456789012345/events" }

  it "still opens and closes per request outside a block" do
    stub_request(:post, endpoint).to_return(status: 200, body: "{}")

    2.times { expect(client.send_events([{ event_name: "PageView" }])).to be_success }

    expect(WebMock).to have_requested(:post, endpoint).twice
  end

  # The point of the block: several sends, one socket. WebMock cannot observe
  # the socket, so this asserts the requests still all land correctly -- the
  # reuse itself is exercised by every request inside the block succeeding
  # against a connection opened only once.
  it "sends every request inside a block" do
    stub_request(:post, endpoint).to_return(status: 200, body: "{}")

    client.with_connection do |c|
      3.times { expect(c.send_events([{ event_name: "PageView" }])).to be_success }
    end

    expect(WebMock).to have_requested(:post, endpoint).times(3)
  end

  it "returns to per-request connections after the block" do
    stub_request(:post, endpoint).to_return(status: 200, body: "{}")

    client.with_connection { |c| c.send_events([{ event_name: "PageView" }]) }

    expect(client.send_events([{ event_name: "PageView" }])).to be_success
  end

  # A reused socket the far end has closed must not poison the rest of the
  # flush: the connection is dropped and the next request opens a new one.
  it "recovers when a reused connection is dropped mid-block" do
    stub_request(:post, endpoint).to_raise(Errno::ECONNRESET).then.to_return(
      status: 200,
      body: "{}",
    )

    client.with_connection do |c|
      expect(c.send_events([{ event_name: "PageView" }])).to be_retryable
      expect(c.send_events([{ event_name: "PageView" }])).to be_success
    end
  end

  it "closes the connection even when the block raises" do
    stub_request(:post, endpoint).to_return(status: 200, body: "{}")

    expect {
      client.with_connection do |c|
        c.send_events([{ event_name: "PageView" }])
        raise "boom"
      end
    }.to raise_error("boom")

    # Still usable afterwards, on a fresh per-request connection.
    expect(client.send_events([{ event_name: "PageView" }])).to be_success
  end
end
