require "spec_helper"

RSpec.describe "iface plugin validator coverage" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  describe "Http plugin" do
    it "validator passes when no auth is declared (auth-nil branch)" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface http upstream
         base-url "https://api.example.test"
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors).to be_empty
    end

    it "validator errors when auth bearer references a missing secret" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface http upstream
         base-url "https://api.example.test"
         auth bearer secret GHOST
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/unknown secret 'GHOST'/)
    end

    it "validator passes when auth secret is declared" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret REAL
         source env REAL
        exit
        interface http upstream
         base-url "https://api.example.test"
         auth bearer secret REAL
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors).to be_empty
    end
  end

  describe "Llm plugin" do
    it "validator rejects auth bearer on a subprocess provider" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret K
         source env K
        exit
        interface llm robot
         provider codex_cli
         model gpt-5-codex
         auth bearer secret K
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/uses a CLI binary and does not accept `auth bearer secret`/)
    end

    it "validator rejects binary/home/sandbox on an HTTP provider" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface llm http_one
         provider anthropic
         model x
         binary /usr/local/bin/whatever
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/binary.*only valid for codex_cli/i)
    end
  end

  describe "LocalRepo plugin" do
    it "validator passes for a well-formed declaration" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface local_repo workspace
         root /opt/repos
         whitelist vosio/app
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors).to be_empty
    end

    it "validator errors when root is a relative path" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface local_repo workspace
         root opt/repos
         whitelist vosio/app
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/root must be an absolute path/)
    end

    it "validator errors when whitelist is empty after stripping" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface local_repo workspace
         root /opt/repos
         whitelist " , , "
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/whitelist must list at least one repo/)
    end
  end

  describe "Mcp plugin" do
    it "validator passes when `server raw` has no templating" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp svr
         server raw "docker run --rm -i my-image"
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .not_to match(/does not template/)
    end

    it "validator errors when `server raw` spec contains `{{...}}`" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp svr
         server raw "docker run --rm -i {{event.image}}"
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/does not template/)
    end
  end

  describe "Webhook plugin" do
    it "validator passes when no auth/hmac declared" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook hook
         path /hook
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors).to be_empty
    end

    it "validator errors when hmac-sha256 references a missing secret" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook hook
         path /hook
         hmac-sha256 secret GHOST header X-Hub-Signature-256
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/unknown secret 'GHOST'.*hmac-sha256/)
    end

    it "validator passes when hmac-sha256 references a declared secret" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret HMAC
         source env HMAC
        exit
        interface webhook hook
         path /hook
         hmac-sha256 secret HMAC header X-Hub-Signature-256
        exit
      PRC
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors).to be_empty
    end
  end
end
