require "spec_helper"
require "rack"

RSpec.describe Prouterd::API::Auth do
  describe ".token_from" do
    it "returns the bearer token from an Authorization header" do
      env = { "HTTP_AUTHORIZATION" => "Bearer s3cret" }
      expect(described_class.token_from(env)).to eq("s3cret")
    end

    it "trims whitespace after the Bearer scheme" do
      env = { "HTTP_AUTHORIZATION" => "Bearer   s3cret   " }
      expect(described_class.token_from(env)).to eq("s3cret")
    end

    it "returns nil for an empty Bearer value" do
      env = { "HTTP_AUTHORIZATION" => "Bearer " }
      expect(described_class.token_from(env)).to be_nil
    end

    it "ignores non-Bearer schemes" do
      env = { "HTTP_AUTHORIZATION" => "Basic ZGVtbzpkZW1v" }
      expect(described_class.token_from(env)).to be_nil
    end

    it "falls back to ?token= when no Authorization header is present" do
      env = { "QUERY_STRING" => "token=q-secret&other=ignored" }
      expect(described_class.token_from(env)).to eq("q-secret")
    end

    it "prefers the Authorization header over the query parameter" do
      env = {
        "HTTP_AUTHORIZATION" => "Bearer header-wins",
        "QUERY_STRING" => "token=query-loses"
      }
      expect(described_class.token_from(env)).to eq("header-wins")
    end

    it "returns nil when neither header nor query supplies a token" do
      expect(described_class.token_from({})).to be_nil
    end

    it "returns nil for an empty ?token= value" do
      env = { "QUERY_STRING" => "token=" }
      expect(described_class.token_from(env)).to be_nil
    end

    it "accepts a Rack::Request" do
      request = Rack::Request.new("HTTP_AUTHORIZATION" => "Bearer from-req")
      expect(described_class.token_from(request)).to eq("from-req")
    end
  end

  describe ".check_bearer" do
    let(:expected) { "the-real-secret" }

    it "returns nil on a matching token" do
      env = { "HTTP_AUTHORIZATION" => "Bearer #{expected}" }
      expect(described_class.check_bearer(env, expected)).to be_nil
    end

    it "returns 401 unauthorized when no token presented" do
      result = described_class.check_bearer({}, expected)
      expect(result).to eq([401, "unauthorized", "missing bearer token"])
    end

    it "returns 503 unavailable when the daemon has no expected token configured" do
      env = { "HTTP_AUTHORIZATION" => "Bearer anything" }
      expect(described_class.check_bearer(env, nil)).to eq(
        [503, "unavailable", "auth secret not configured"]
      )
      expect(described_class.check_bearer(env, "")).to eq(
        [503, "unavailable", "auth secret not configured"]
      )
    end

    it "returns 403 forbidden on a mismatched token" do
      env = { "HTTP_AUTHORIZATION" => "Bearer wrong" }
      expect(described_class.check_bearer(env, expected)).to eq(
        [403, "forbidden", "bearer token rejected"]
      )
    end

    it "uses Rack::Utils.secure_compare (no string == shortcut)" do
      # If anyone ever swaps in `==`, this test still passes — but the
      # explicit expectation pins the security guarantee in code so it's
      # caught in code review if the comparison is downgraded.
      expect(Rack::Utils).to receive(:secure_compare).with("provided", expected).and_call_original
      env = { "HTTP_AUTHORIZATION" => "Bearer provided" }
      described_class.check_bearer(env, expected)
    end
  end

  describe "cookie session helpers" do
    let(:sessions) { double("session_store") }

    describe ".cookie_session_valid?" do
      it "returns false when no session store is wired (open / bearer-only deploy)" do
        env = { "HTTP_COOKIE" => "prouterd_session=abc" }
        expect(described_class.cookie_session_valid?(env, nil)).to be(false)
      end

      it "returns false when no cookie is sent" do
        allow(sessions).to receive(:valid?).with(nil).and_return(false)
        expect(described_class.cookie_session_valid?({}, sessions)).to be(false)
      end

      it "delegates the cookie value to the session store" do
        env = { "HTTP_COOKIE" => "other=x; prouterd_session=session-id-xyz; trailing=y" }
        expect(sessions).to receive(:valid?).with("session-id-xyz").and_return(true)
        expect(described_class.cookie_session_valid?(env, sessions)).to be(true)
      end
    end

    describe ".session_id_from" do
      it "extracts the prouterd_session cookie value" do
        env = { "HTTP_COOKIE" => "a=1; prouterd_session=sid42; b=2" }
        expect(described_class.session_id_from(env)).to eq("sid42")
      end

      it "returns nil when the cookie is absent" do
        expect(described_class.session_id_from({})).to be_nil
      end
    end

    describe ".parse_cookies" do
      it "handles single cookie" do
        expect(described_class.parse_cookies("a=1")).to eq("a" => "1")
      end

      it "handles multiple cookies with whitespace around the separator" do
        expect(described_class.parse_cookies("a=1; b=2;c=3"))
          .to eq("a" => "1", "b" => "2", "c" => "3")
      end

      it "handles cookies without values" do
        expect(described_class.parse_cookies("flag=; name=v"))
          .to eq("flag" => "", "name" => "v")
      end

      it "ignores empty pairs" do
        expect(described_class.parse_cookies("")).to eq({})
        expect(described_class.parse_cookies("; ;")).to eq({})
      end
    end
  end
end
