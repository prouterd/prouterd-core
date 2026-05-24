require "spec_helper"
require "rack"
require "stringio"

RSpec.describe Prouterd::API::BodyReader do
  Host = Struct.new(:foo) { include Prouterd::API::BodyReader }

  let(:reader) { Host.new(nil) }

  def fake_request(body, max_body_bytes: nil)
    env = { "prouterd.max_body_bytes" => max_body_bytes }
    body_io = StringIO.new(body)
    request = Rack::Request.new(env)
    allow(request).to receive(:body).and_return(body_io)
    request
  end

  it "returns the body verbatim when under the cap" do
    body = "hello world"
    expect(reader.read_bounded_body(fake_request(body, max_body_bytes: 1024))).to eq(body)
  end

  it "raises PayloadTooLarge when the body exceeds the cap" do
    body = "x" * 200
    expect {
      reader.read_bounded_body(fake_request(body, max_body_bytes: 50))
    }.to raise_error(Prouterd::API::PayloadTooLarge) do |e|
      expect(e.limit_bytes).to eq(50)
      expect(e.message).to eq("request body too large")
    end
  end

  it "falls back to App::DEFAULT_MAX_BODY_BYTES when the env cap is unset / non-positive" do
    body = "small"
    request = fake_request(body, max_body_bytes: 0)
    expect(reader.read_bounded_body(request)).to eq(body)
  end

  it "returns '' when the request body is nil" do
    request = Rack::Request.new({})
    allow(request).to receive(:body).and_return(nil)
    expect(reader.read_bounded_body(request)).to eq("")
  end

  it "rewinds the body before reading when supported" do
    body = "abc"
    io = StringIO.new(body)
    io.read # consume
    request = Rack::Request.new({})
    allow(request).to receive(:body).and_return(io)
    expect(reader.read_bounded_body(request)).to eq(body)
  end
end
