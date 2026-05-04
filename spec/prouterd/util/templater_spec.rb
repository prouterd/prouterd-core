require "spec_helper"

RSpec.describe Prouterd::Util::Templater do
  describe ".render" do
    it "passes through strings without {{ tokens" do
      expect(described_class.render("plain", {})).to eq("plain")
    end

    it "substitutes a top-level path" do
      expect(described_class.render("hi {{name}}", "name" => "world")).to eq("hi world")
    end

    it "substitutes a dotted path" do
      ctx = { "event" => { "user" => { "id" => 42 } } }
      expect(described_class.render("user/{{event.user.id}}", ctx)).to eq("user/42")
    end

    it "trims whitespace inside braces" do
      expect(described_class.render("[{{ name }}]", "name" => "x")).to eq("[x]")
    end

    it "renders a missing path as empty string" do
      expect(described_class.render("a={{missing.path}}b", {})).to eq("a=b")
    end

    it "renders nil as empty string" do
      expect(described_class.render("{{x}}", "x" => nil)).to eq("")
    end

    it "renders booleans and numbers via to_s" do
      expect(described_class.render("{{a}} {{b}} {{c}}", "a" => true, "b" => 0.5, "c" => 7))
        .to eq("true 0.5 7")
    end

    it "JSON-encodes hash and array values" do
      expect(described_class.render("p={{p}}", "p" => { "k" => "v" }))
        .to eq('p={"k":"v"}')
      expect(described_class.render("a={{a}}", "a" => [1, 2, 3])).to eq("a=[1,2,3]")
    end

    it "leaves non-template tokens (just '{{ ' ) alone" do
      expect(described_class.render("hi {{}}", {})).to eq("hi {{}}")
      expect(described_class.render("{ {x} }", "x" => "y")).to eq("{ {x} }")
    end

    it "supports a Runtime::Context as the source via #get" do
      ctx = Prouterd::Runtime::Context.new("event" => { "user" => { "id" => "u-1" } })
      expect(described_class.render("uid={{event.user.id}}", ctx)).to eq("uid=u-1")
    end

    it "returns the template unchanged when given non-string" do
      expect(described_class.render(42, {})).to eq(42)
      expect(described_class.render(nil, {})).to be_nil
    end

    it "handles multiple substitutions in one string" do
      expect(described_class.render("{{a}}-{{b}}-{{c}}", "a" => "x", "b" => "y", "c" => "z"))
        .to eq("x-y-z")
    end
  end
end
