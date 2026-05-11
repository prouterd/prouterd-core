require "spec_helper"

RSpec.describe Prouterd::Iface::HttpCaller do
  let(:caller) { described_class.new }

  def make_request(type_fields:, env: {}, timeout_ms: nil)
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_test", process_name: "p", block_name: "b",
      execution_type: "http", attempt: 1, env: env,
      input_json: {}, timeout_ms: timeout_ms,
      type_fields: type_fields, staged_inputs: {}
    )
  end

  def ok_response(status: 200, body_json: { "ok" => true }, body_text: nil)
    Prouterd::Iface::HttpClient::Response.new(
      status: status,
      body_text: body_text || (body_json ? JSON.dump(body_json) : ""),
      body_json: body_json
    )
  end

  describe "URL composition" do
    it "joins base-url + path + query verbatim" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |**kw|
        seen = kw
        ok_response
      end
      caller.run(make_request(type_fields: {
        "base-url" => "https://api.example.com/v1",
        "path"     => "/users/42",
        "query"    => "expand=true&fmt=json"
      }))
      expect(seen[:uri].to_s).to eq("https://api.example.com/v1/users/42?expand=true&fmt=json")
    end

    it "strips a trailing / on base when path is absolute" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(type_fields: {
        "base-url" => "https://api.example.com/v1/",
        "path"     => "/x"
      }))
      expect(seen[:uri].to_s).to eq("https://api.example.com/v1/x")
    end

    it "concatenates query with '?' when base has no query, '&' otherwise" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(type_fields: {
        "base-url" => "https://api.example.com/v1?key=k",
        "query"    => "id=42"
      }))
      expect(seen[:uri].to_s).to eq("https://api.example.com/v1?key=k&id=42")
    end

    it "errors with invalid_interface when base-url is empty" do
      result = caller.run(make_request(type_fields: { "base-url" => "" }))
      expect(result.error_type).to eq("invalid_interface")
      expect(result.error_message).to include("missing base-url")
    end

    it "errors with invalid_url when the result is not http(s)" do
      result = caller.run(make_request(type_fields: { "base-url" => "ftp://example.com" }))
      expect(result.error_type).to eq("invalid_url")
    end
  end

  describe "method + body + content-type" do
    it "defaults to GET when no method is set" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(seen[:method]).to eq("GET")
    end

    it "upcases the method" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(type_fields: { "base-url" => "https://x/", "method" => "post" }))
      expect(seen[:method]).to eq("POST")
    end

    it "attaches a non-empty body verbatim and sets content-type=application/json" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      body = '{"hi":"there"}'
      caller.run(make_request(type_fields: {
        "base-url" => "https://x/", "method" => "POST", "body-json" => body
      }))
      expect(seen[:body]).to eq(body)
      expect(seen[:headers]["content-type"]).to eq("application/json")
    end

    it "omits content-type when no body is supplied" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(seen[:headers]).not_to have_key("content-type")
    end
  end

  describe "auth header" do
    let(:bearer_auth) { Prouterd::Config::AST::Auth.new(scheme: "bearer", secret_name: "TOKEN", line: 0) }

    it "adds Authorization: Bearer <token> from env" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(
        type_fields: { "base-url" => "https://x/", "auth" => bearer_auth },
        env: { "TOKEN" => "s3cret" }
      ))
      expect(seen[:headers]["authorization"]).to eq("Bearer s3cret")
    end

    it "omits Authorization when the env var is unset" do
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(
        type_fields: { "base-url" => "https://x/", "auth" => bearer_auth },
        env: {}
      ))
      expect(seen[:headers]).not_to have_key("authorization")
    end

    it "ignores unknown auth schemes" do
      weird = Prouterd::Config::AST::Auth.new(scheme: "basic", secret_name: "TOKEN", line: 0)
      seen = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) { |**kw| seen = kw; ok_response }
      caller.run(make_request(
        type_fields: { "base-url" => "https://x/", "auth" => weird },
        env: { "TOKEN" => "s3cret" }
      ))
      expect(seen[:headers]).not_to have_key("authorization")
    end
  end

  describe "response handling" do
    it "2xx with JSON body: exit_code=0, output_json populated, empty stdout" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_return(ok_response(status: 201, body_json: { "id" => 42 }))
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.exit_code).to eq(0)
      expect(result.output_json).to eq("id" => 42)
      expect(result.stdout).to eq("")
      expect(result.error_type).to be_nil
    end

    it "2xx with plain-text body: wraps it as {status, body}, stdout carries the text" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_return(ok_response(status: 200, body_json: nil, body_text: "hello"))
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.exit_code).to eq(0)
      expect(result.output_json).to eq("status" => 200, "body" => "hello")
      expect(result.stdout).to eq("hello")
    end

    it "non-2xx maps to error_type='http_status' and surfaces the first line of the body" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_return(ok_response(status: 500, body_json: nil, body_text: "Internal Server Error\nstack..."))
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.exit_code).to eq(500)
      expect(result.error_type).to eq("http_status")
      expect(result.error_message).to eq("HTTP 500: Internal Server Error")
      expect(result.output_json).to be_nil
    end

    it "non-2xx with JSON body: stdout carries serialized JSON" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_return(ok_response(status: 422, body_json: { "error" => "validation" }, body_text: '{"error":"validation"}'))
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.exit_code).to eq(422)
      expect(result.stdout).to eq('{"error":"validation"}')
    end
  end

  describe "error mapping" do
    it "TimeoutError → error_type='timeout'" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(Prouterd::Iface::HttpClient::TimeoutError, "read timeout")
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.error_type).to eq("timeout")
      expect(result.error_message).to include("read timeout")
      expect(result.exit_code).to be_nil
    end

    it "RequestError → error_type='http_error'" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(Prouterd::Iface::HttpClient::RequestError, "Errno::ECONNREFUSED: ...")
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.error_type).to eq("http_error")
    end

    it "ArgumentError (e.g. unsupported HTTP method) → error_type='http_error'" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(ArgumentError, "unsupported HTTP method: SAUSAGE")
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/", "method" => "SAUSAGE" }))
      expect(result.error_type).to eq("http_error")
    end
  end

  describe "timing instrumentation (CallerTiming)" do
    it "populates duration_ms and ISO8601 timestamps on the ExecutionResult" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(ok_response)
      result = caller.run(make_request(type_fields: { "base-url" => "https://x/" }))
      expect(result.duration_ms).to be_a(Integer).and be >= 0
      expect(result.started_at).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(result.finished_at).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end
end
