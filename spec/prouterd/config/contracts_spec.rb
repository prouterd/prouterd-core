require "spec_helper"

RSpec.describe "Phase 13 contracts DSL" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def validate(prc)
    doc = parse(prc)
    [doc, Prouterd::Config::Validator.validate(doc)]
  end

  describe "parser" do
    it "parses a simple contract with type + range + enum + format" do
      doc = parse(<<~PRC)
        router x
        exit
        contract lead_ok
         require lead.score type integer
         require lead.score min 0
         require lead.score max 100
         require lead.email type string format email
         require lead.region in "US","EU","KZ"
         optional lead.tags type array
         on violation retry
        exit
      PRC
      c = doc.contracts.first
      expect(c.name).to eq("lead_ok")
      expect(c.on_violation).to eq("retry")

      score = c.requirements.find { |r| r.path == "lead.score" }
      expect(score.required).to be(true)
      expect(score.type).to eq("integer")
      expect(score.min).to eq(0)
      expect(score.max).to eq(100)

      email = c.requirements.find { |r| r.path == "lead.email" }
      expect(email.format).to eq("email")
      expect(email.type).to eq("string")

      region = c.requirements.find { |r| r.path == "lead.region" }
      expect(region.enum).to eq(%w[US EU KZ])

      tags = c.requirements.find { |r| r.path == "lead.tags" }
      expect(tags.required).to be(false)
      expect(tags.type).to eq("array")
    end

    it "merges multiple lines for the same path into one Requirement" do
      doc = parse(<<~PRC)
        router x
        exit
        contract c
         require lead.score type integer
         require lead.score min 0
         require lead.score max 100
        exit
      PRC
      c = doc.contracts.first
      expect(c.requirements.length).to eq(1)
      r = c.requirements.first
      expect(r.type).to eq("integer")
      expect(r.min).to eq(0)
      expect(r.max).to eq(100)
    end

    it "rejects unknown attribute" do
      expect do
        parse(<<~PRC)
          router x
          exit
          contract c
           require x foo bar
          exit
        PRC
      end.to raise_error(Prouterd::Config::ParseError, /unknown constraint attribute 'foo'/)
    end

    it "rejects invalid type" do
      expect do
        parse(<<~PRC)
          router x
          exit
          contract c
           require x type weird
          exit
        PRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid type 'weird'/)
    end

    it "rejects invalid on-violation" do
      expect do
        parse(<<~PRC)
          router x
          exit
          contract c
           on violation panic
          exit
        PRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid on-violation 'panic'/)
    end
  end

  describe "validator" do
    it "rejects block referencing unknown contract" do
      _, r = validate(<<~PRC)
        router x
        exit
        process p
         block b
          type docker
           image x
          exit
          input e
          output o
          contract ghost
         exit
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/unknown contract 'ghost'/)
    end

    it "accepts block referencing existing contract" do
      _, r = validate(<<~PRC)
        router x
        exit
        contract good
         require x type integer
        exit
        process p
         block b
          type docker
           image x
          exit
          input e
          output o
          contract good
         exit
        exit
      PRC
      expect(r.errors).to be_empty
    end

    it "errors when min > max" do
      _, r = validate(<<~PRC)
        router x
        exit
        contract c
         require x type integer min 100 max 0
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/min 100 > max 0/)
    end

    it "errors on duplicate contract name" do
      _, r = validate(<<~PRC)
        router x
        exit
        contract c
         require x type integer
        exit
        contract c
         require y type string
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/duplicate contract 'c'/)
    end
  end

  describe "renderer roundtrip" do
    it "round-trips parse -> render -> parse" do
      original = parse(<<~PRC)
        router x
        exit
        contract lead_ok
         require lead.score type integer
         require lead.score min 0
         require lead.score max 100
         require lead.email type string format email
         require lead.region in "US","EU","KZ"
         optional lead.tags type array
         on violation retry
        exit
      PRC
      rendered = Prouterd::Config::Renderer.render(original)
      expect(rendered).to include("contract lead_ok")
      expect(rendered).to include("on violation retry")

      reparsed = parse(rendered)
      orig_c = original.contracts.first
      again_c = reparsed.contracts.first
      expect(again_c.name).to eq(orig_c.name)
      expect(again_c.on_violation).to eq(orig_c.on_violation)
      expect(again_c.requirements.length).to eq(orig_c.requirements.length)
    end
  end
end
