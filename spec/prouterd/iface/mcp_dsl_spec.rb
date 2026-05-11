require "spec_helper"

RSpec.describe "interface mcp DSL surface" do
  def parse(src)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  def render(doc)
    Prouterd::Config::Renderer.render(doc)
  end

  def validate(doc)
    Prouterd::Config::Validator.validate(doc)
  end

  let(:source) do
    <<~PRC
      router demo
      exit
      secret JIRA_TOKEN
       source env JIRA_TOKEN
      exit
      interface mcp atlassian
       server npx "@atlassian/mcp-server@1.4.2"
       cwd /opt/atp
       env JIRA_URL "https://example.atlassian.net"
       secret JIRA_TOKEN
       timeout-tool-call 30s
      exit
      interface llm codex
       provider anthropic
       model claude-sonnet-4-6
      exit
      process triage
       block run
        interface llm codex
        prompt "do the thing"
        agentic on
        mcp atlassian
        allowed-tools atlassian.search_issues, atlassian.get_issue
        tool-call-limit 5
       exit
      exit
    PRC
  end

  describe "parser" do
    it "captures the four server kinds" do
      doc = parse(<<~PRC)
        interface mcp a
         server npx "@some/pkg@1"
        exit
        interface mcp b
         server uvx "mcp-server-thing@0.5"
        exit
        interface mcp c
         server bin "/usr/local/bin/foo-mcp"
        exit
        interface mcp d
         server raw "docker run --rm -i some/image:latest"
        exit
      PRC
      kinds = doc.interfaces.map { |i| i.type_fields["server"]["kind"] }
      specs = doc.interfaces.map { |i| i.type_fields["server"]["spec"] }
      expect(kinds).to eq(%w[npx uvx bin raw])
      expect(specs).to eq([
        "@some/pkg@1",
        "mcp-server-thing@0.5",
        "/usr/local/bin/foo-mcp",
        "docker run --rm -i some/image:latest"
      ])
    end

    it "rejects an unknown server kind" do
      expect {
        parse("interface mcp x\n server gem \"foo\"\nexit\n")
      }.to raise_error(Prouterd::Config::ParseError, /invalid server kind 'gem'/)
    end

    it "accumulates multiple secret directives on one mcp interface" do
      doc = parse(<<~PRC)
        interface mcp x
         server npx "@a/b"
         secret ONE
         secret TWO
         secret THREE
        exit
      PRC
      expect(doc.interfaces.first.type_fields["secret"]).to eq(%w[ONE TWO THREE])
    end

    it "captures block.mcp_refs and namespaced allowed-tools" do
      doc = parse(source)
      block = doc.processes.first.blocks.first
      expect(block.mcp_refs).to eq(%w[atlassian])
      expect(block.allowed_tools).to eq(%w[atlassian.search_issues atlassian.get_issue])
    end

    it "rejects using an mcp interface as a direct process block" do
      expect {
        parse(<<~PRC)
          router demo
          exit
          interface mcp fs
           server raw "ruby fake_server.rb"
          exit
          process p
           block read
            interface mcp fs
           exit
          exit
        PRC
      }.to raise_error(Prouterd::Config::ParseError, /runtime-only/)
    end

    it "rejects a malformed namespaced tool name" do
      bad = source.sub("atlassian.search_issues", "atlassian.")
      expect { parse(bad) }
        .to raise_error(Prouterd::Config::ParseError, /invalid tool name/)
    end
  end

  describe "renderer round-trip" do
    it "round-trips through parse → render → parse" do
      doc1 = parse(source)
      rendered = render(doc1)
      doc2 = parse(rendered)
      expect(render(doc2)).to eq(rendered)

      iface = doc2.interfaces.find { |i| i.type == "mcp" }
      expect(iface.type_fields["server"]).to eq("kind" => "npx", "spec" => "@atlassian/mcp-server@1.4.2")
      expect(iface.type_fields["cwd"]).to eq("/opt/atp")
      expect(iface.type_fields["secret"]).to eq(%w[JIRA_TOKEN])
      expect(iface.type_fields["timeout-tool-call"]).to eq(30_000)
    end
  end

  describe "validator" do
    it "accepts the example document" do
      result = validate(parse(source))
      expect(result.errors.map(&:message)).to be_empty
    end

    it "errors on `secret <NAME>` referencing an undeclared secret" do
      bad = source.sub("secret JIRA_TOKEN\n source env JIRA_TOKEN\nexit\n", "")
      result = validate(parse(bad))
      expect(result.errors.map(&:message))
        .to include(a_string_matching(/references undeclared secret 'JIRA_TOKEN'/))
    end

    it "errors when a block's mcp ref names a non-mcp interface" do
      doc = parse(source)
      doc.processes.first.blocks.first.mcp_refs.replace(%w[codex])  # codex is the LLM, not mcp
      result = validate(doc)
      expect(result.errors.map(&:message))
        .to include(a_string_matching(/mcp references undeclared interface 'codex'/))
    end

    it "errors when allowed-tools namespace is not declared as `interface mcp`" do
      doc = parse(source)
      doc.processes.first.blocks.first.allowed_tools << "ghost.thing"
      result = validate(doc)
      expect(result.errors.map(&:message))
        .to include(a_string_matching(/namespace 'ghost' is not a declared `interface mcp`/))
    end

    it "errors when allowed-tools namespace is not in the block's mcp list" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp a
         server npx "@one/pkg"
        exit
        interface mcp b
         server npx "@two/pkg"
        exit
        interface llm codex
         provider anthropic
         model x
        exit
        process p
         block r
          interface llm codex
          prompt "x"
          agentic on
          mcp a
          allowed-tools b.do_thing
         exit
        exit
      PRC
      result = validate(doc)
      expect(result.errors.map(&:message))
        .to include(a_string_matching(/namespace 'b' is not in this block's `mcp` list/))
    end

    it "rejects {{...}} templating in `server raw` (shell-injection guard)" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp x
         server raw "docker run -e TOK={{secret.X}} some/image"
        exit
      PRC
      result = validate(doc)
      expect(result.errors.map(&:message))
        .to include(a_string_matching(/`server raw` does not template/))
    end
  end
end
