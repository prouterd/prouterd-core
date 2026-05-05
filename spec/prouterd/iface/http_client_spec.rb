require "spec_helper"
require "json"
require "net/http"

RSpec.describe Prouterd::Iface::HttpClient do
  before do
    @captured = nil

    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:request) do |req|
      headers = {}
      req.each_header { |k, v| headers[k] = v }
      Thread.current[:captured_http_client] = {
        method: req.method,
        path:   req.path,
        body:   req.body,
        headers: headers
      }
      Thread.current[:next_response_or_raise]
    end

    allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
      raised = Thread.current[:next_raise]
      raise raised if raised

      block.call(fake_adapter)
    end
  end

  after { Thread.current[:next_raise] = nil }

  def stub_response(status:, body:)
    response = Net::HTTPResponse.send(:response_class, status.to_s).new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, body.is_a?(String) ? body : JSON.dump(body))
    response.instance_variable_set(:@read, true)
    Thread.current[:next_response_or_raise] = response
  end

  def captured
    Thread.current[:captured_http_client]
  end

  def uri(s); URI.parse(s); end

  it "performs a GET, returns Response with parsed body_json on 2xx" do
    stub_response(status: 200, body: { "ok" => true })

    response = described_class.request(method: "GET", uri: uri("https://api.example.test/v1/x"))

    expect(response).to be_a(described_class::Response)
    expect(response.status).to eq(200)
    expect(response.body_json).to eq("ok" => true)
    expect(response.body_text).to eq('{"ok":true}')
    expect(captured[:method]).to eq("GET")
    expect(captured[:path]).to eq("/v1/x")
  end

  it "POSTs the supplied body and merges the headers" do
    stub_response(status: 200, body: { "rcv" => true })

    described_class.request(
      method:  "POST",
      uri:     uri("https://api.example.test/x"),
      headers: { "content-type" => "application/json", "x-trace" => "abc" },
      body:    '{"k":1}'
    )
    expect(captured[:method]).to eq("POST")
    expect(captured[:body]).to eq('{"k":1}')
    expect(captured[:headers]["content-type"]).to eq("application/json")
    expect(captured[:headers]["x-trace"]).to eq("abc")
  end

  it "leaves body_json nil when the body is not parseable JSON" do
    stub_response(status: 200, body: "<html>oops</html>")
    response = described_class.request(method: "GET", uri: uri("https://x.test/y"))
    expect(response.body_json).to be_nil
    expect(response.body_text).to eq("<html>oops</html>")
  end

  it "raises TimeoutError on Net::OpenTimeout / Net::ReadTimeout" do
    Thread.current[:next_raise] = Net::OpenTimeout.new("connect timed out")
    expect {
      described_class.request(method: "GET", uri: uri("https://x.test/y"))
    }.to raise_error(described_class::TimeoutError, /connect timed out/)

    Thread.current[:next_raise] = Net::ReadTimeout.new("read timed out")
    expect {
      described_class.request(method: "GET", uri: uri("https://x.test/y"))
    }.to raise_error(described_class::TimeoutError, /read timed out/)
  end

  it "raises RequestError on generic transport failures" do
    Thread.current[:next_raise] = SocketError.new("getaddrinfo: Name or service not known")
    expect {
      described_class.request(method: "GET", uri: uri("https://nonexistent.example.test/y"))
    }.to raise_error(described_class::RequestError, /SocketError.*getaddrinfo/)
  end

  it "raises ArgumentError on unknown HTTP methods" do
    expect {
      described_class.request(method: "BREW", uri: uri("https://x.test/teapot"))
    }.to raise_error(ArgumentError, /unsupported HTTP method.*BREW/)
  end

  describe ".timeout_seconds" do
    it "converts ms to seconds with a 1-second floor" do
      expect(described_class.timeout_seconds(5_000)).to eq(5.0)
      expect(described_class.timeout_seconds(500)).to eq(1)   # floored
      expect(described_class.timeout_seconds(0)).to eq(1)
    end

    it "falls back to the default when timeout_ms is nil" do
      expect(described_class.timeout_seconds(nil)).to eq(described_class::DEFAULT_TIMEOUT_SECONDS)
      expect(described_class.timeout_seconds(nil, default: 90)).to eq(90)
    end
  end
end
