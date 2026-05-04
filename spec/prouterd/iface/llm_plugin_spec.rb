require "spec_helper"

RSpec.describe "interface llm plugin schema" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  it "is registered as outbound" do
    plugin = Prouterd::Iface::Registry.lookup("llm")
    expect(plugin).not_to be_nil
    expect(plugin.outbound?).to be(true)
  end

  it "parses and validates a complete declaration" do
    doc = parse(<<~PRC)
      router demo
      exit
      secret CLAUDE_KEY
       source env CLAUDE_KEY
      exit
      interface llm claude
       provider anthropic
       model claude-haiku-4-5-20251001
       auth bearer secret CLAUDE_KEY
      exit
    PRC

    iface = doc.interfaces.first
    expect(iface.type).to eq("llm")
    expect(iface.type_fields["provider"]).to eq("anthropic")
    expect(iface.type_fields["model"]).to eq("claude-haiku-4-5-20251001")
    expect(iface.type_fields["auth"].secret_name).to eq("CLAUDE_KEY")

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors).to be_empty
  end

  it "errors when provider is missing" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface llm broken
       model claude-haiku-4-5-20251001
      exit
    PRC

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n"))
      .to match(/interface 'broken' \(llm\) missing 'provider'/)
  end

  it "errors when provider is not in the enum" do
    expect {
      parse(<<~PRC)
        router demo
        exit
        interface llm bad
         provider gemini
         model x
        exit
      PRC
    }.to raise_error(Prouterd::Config::ConfigError, /provider.*gemini/)
  end

  it "errors when auth references a non-existent secret" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface llm orphan
       provider anthropic
       model m
       auth bearer secret GHOST_KEY
      exit
    PRC

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n"))
      .to match(/unknown secret 'GHOST_KEY'/)
  end

  it "validator errors when a block omits the required 'prompt' call-field" do
    doc = parse(<<~PRC)
      router demo
      exit
      secret K
       source env K
      exit
      interface llm claude
       provider anthropic
       model m
       auth bearer secret K
      exit
      process p
       block call_it
        interface llm claude
       exit
      exit
    PRC

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n"))
      .to match(/missing call-field 'prompt'/)
  end

  it "block referencing the llm interface accepts call-fields" do
    doc = parse(<<~PRC)
      router demo
      exit
      secret K
       source env K
      exit
      interface llm claude
       provider anthropic
       model m
       auth bearer secret K
      exit
      process p
       block summarize
        interface llm claude
        prompt "{{event.body}}"
        system "be brief"
        max-tokens 256
        temperature 0.2
       exit
      exit
    PRC

    block = doc.processes.first.blocks.first
    expect(block.interface_ref.type).to eq("llm")
    expect(block.interface_ref.name).to eq("claude")
    expect(block.type_fields["prompt"]).to eq("{{event.body}}")
    expect(block.type_fields["system"]).to eq("be brief")
    expect(block.type_fields["max-tokens"]).to eq("256")
    expect(block.type_fields["temperature"]).to eq("0.2")
  end

  it "renders a parse->render roundtrip identically" do
    src = <<~PRC
      router demo
      exit
      secret K
       source env K
      exit
      interface llm claude
       provider anthropic
       model claude-haiku-4-5-20251001
       auth bearer secret K
      exit
    PRC

    first  = Prouterd::Config::Renderer.render(parse(src))
    second = Prouterd::Config::Renderer.render(parse(first))
    expect(second).to eq(first)
    expect(first).to include("interface llm claude")
    expect(first).to include("provider anthropic")
    expect(first).to include("auth bearer secret K")
  end
end
