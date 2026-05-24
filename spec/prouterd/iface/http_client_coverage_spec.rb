require "spec_helper"
require "json"
require "net/http"

RSpec.describe Prouterd::Iface::HttpClient do
  before do
    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:request) do |req|
      Thread.current[:captured_http_client] = {
        method: req.method,
        path:   req.path,
        body:   req.body
      }
      Thread.current[:next_response_or_raise]
    end

    allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
      block.call(fake_adapter)
    end
  end

  def stub_response(status:, body:)
    response = Net::HTTPResponse.send(:response_class, status.to_s).new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    Thread.current[:next_response_or_raise] = response
  end

  def captured
    Thread.current[:captured_http_client]
  end

  def uri(s); URI.parse(s); end

  it "leaves body_json nil and body_text empty when the upstream returns an empty body" do
    stub_response(status: 204, body: "")
    response = described_class.request(method: "GET", uri: uri("https://api.test/empty"))
    expect(response.status).to eq(204)
    expect(response.body_text).to eq("")
    expect(response.body_json).to be_nil
  end

  it "skips body assignment when body kwarg is an empty string" do
    stub_response(status: 200, body: "{}")
    described_class.request(
      method: "POST",
      uri:    uri("https://api.test/empty"),
      body:   ""
    )
    expect(captured[:body]).to be_nil
  end
end
