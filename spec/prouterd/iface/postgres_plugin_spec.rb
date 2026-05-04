require "spec_helper"

RSpec.describe "interface postgres plugin schema" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  it "is registered as outbound" do
    plugin = Prouterd::Iface::Registry.lookup("postgres")
    expect(plugin).not_to be_nil
    expect(plugin.outbound?).to be(true)
  end

  it "parses, validates, and renders a complete declaration round-trip" do
    src = <<~PRC
      router demo
      exit
      interface postgres warehouse
       dsn "postgres://x@h/db"
       statement-timeout 5000
      exit
    PRC

    doc = parse(src)
    iface = doc.interfaces.first
    expect(iface.type).to eq("postgres")
    expect(iface.type_fields["dsn"]).to eq("postgres://x@h/db")
    expect(iface.type_fields["statement-timeout"]).to eq("5000")

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors).to be_empty

    first  = Prouterd::Config::Renderer.render(doc)
    second = Prouterd::Config::Renderer.render(parse(first))
    expect(second).to eq(first)
  end

  it "errors when dsn is missing" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface postgres broken
      exit
    PRC

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n"))
      .to match(/interface 'broken' \(postgres\) missing 'dsn'/)
  end

  it "validator errors when a block omits the required 'query' call-field" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface postgres wh
       dsn "postgres://x@h/db"
      exit
      process p
       block lookup
        interface postgres wh
       exit
      exit
    PRC

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n"))
      .to match(/missing call-field 'query'/)
  end
end
