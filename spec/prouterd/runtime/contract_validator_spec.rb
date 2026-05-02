require "spec_helper"

RSpec.describe Prouterd::Runtime::ContractValidator do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def contract(body)
    parse("router x\nexit\ncontract c\n#{body}\nexit\n").contracts.first
  end

  def validate(contract, output)
    described_class.validate(contract, output)
  end

  it "passes valid output" do
    c = contract(" require x type integer min 0 max 100")
    expect(validate(c, { "x" => 50 })).to be_empty
  end

  it "flags missing required" do
    c = contract(" require x type integer")
    v = validate(c, {})
    expect(v.length).to eq(1)
    expect(v.first.kind).to eq(:missing)
  end

  it "ignores missing optional" do
    c = contract(" optional x type integer")
    expect(validate(c, {})).to be_empty
  end

  it "flags wrong type" do
    c = contract(" require x type integer")
    v = validate(c, { "x" => "not-an-int" })
    expect(v.first.kind).to eq(:wrong_type)
  end

  it "flags below min / above max" do
    c = contract(" require x type integer min 0 max 100")
    expect(validate(c, { "x" => -1 }).first.kind).to eq(:below_min)
    expect(validate(c, { "x" => 101 }).first.kind).to eq(:above_max)
  end

  it "flags not in enum" do
    c = contract(" require region in \"US\",\"EU\"")
    expect(validate(c, { "region" => "AS" }).first.kind).to eq(:not_in_enum)
    expect(validate(c, { "region" => "US" })).to be_empty
  end

  it "validates email format" do
    c = contract(" require email type string format email")
    expect(validate(c, { "email" => "x@y.z" })).to be_empty
    expect(validate(c, { "email" => "not-email" }).first.kind).to eq(:format_mismatch)
  end

  it "validates iso8601 format" do
    c = contract(" require ts type string format iso8601")
    expect(validate(c, { "ts" => "2026-05-02T10:00:00Z" })).to be_empty
    expect(validate(c, { "ts" => "Tuesday morning" }).first.kind).to eq(:format_mismatch)
  end

  it "validates UUID format" do
    c = contract(" require id type string format uuid")
    expect(validate(c, { "id" => "550e8400-e29b-41d4-a716-446655440000" })).to be_empty
    expect(validate(c, { "id" => "not-uuid" }).first.kind).to eq(:format_mismatch)
  end

  it "validates URI format" do
    c = contract(" require url type string format uri")
    expect(validate(c, { "url" => "https://example.com/path" })).to be_empty
    expect(validate(c, { "url" => "no-scheme" }).first.kind).to eq(:format_mismatch)
  end

  it "validates regex pattern" do
    c = contract(" require x type string pattern \"^[a-z]+$\"")
    expect(validate(c, { "x" => "abc" })).to be_empty
    expect(validate(c, { "x" => "ABC123" }).first.kind).to eq(:pattern_mismatch)
  end

  it "validates length constraints on strings" do
    c = contract(" require x type string min-length 3 max-length 5")
    expect(validate(c, { "x" => "abc" })).to be_empty
    expect(validate(c, { "x" => "ab" }).first.kind).to eq(:below_min_length)
    expect(validate(c, { "x" => "abcdef" }).first.kind).to eq(:above_max_length)
  end

  it "validates length constraints on arrays" do
    c = contract(" require xs type array length 3")
    expect(validate(c, { "xs" => [1, 2, 3] })).to be_empty
    expect(validate(c, { "xs" => [1, 2] }).first.kind).to eq(:wrong_length)
  end

  it "walks dotted paths into nested objects" do
    c = contract(" require lead.scored.score type integer min 70")
    expect(validate(c, { "lead" => { "scored" => { "score" => 85 } } })).to be_empty
    expect(validate(c, { "lead" => { "scored" => { "score" => 30 } } }).first.kind).to eq(:below_min)
    expect(validate(c, { "lead" => { "scored" => {} } }).first.kind).to eq(:missing)
  end

  it "accumulates multiple violations across paths" do
    c = contract(<<~LINES.strip)
       require a type integer
       require b type string
    LINES
    v = validate(c, { "a" => "wrong", "b" => 42 })
    expect(v.length).to eq(2)
    expect(v.map(&:path).sort).to eq(%w[a b])
  end
end
