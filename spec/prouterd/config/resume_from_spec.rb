require "spec_helper"

# Parser + validator + renderer coverage for the `resume-from` block
# call_field on `interface llm` subprocess blocks.
RSpec.describe "block resume-from directive" do
  def parse(src)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  def validate(src)
    doc = parse(src)
    [doc, Prouterd::Config::Validator.validate(doc)]
  end

  let(:two_block_template) do
    <<~PRC
      router demo
      exit
      interface llm m
       provider %{provider}
       model some-model
      exit
      process p
       block draft
        interface llm m
        prompt "first"
       exit
       block revise
        interface llm m
        prompt "second"
        resume-from "{{draft.session_id}}"
       exit
       route draft revise
      exit
    PRC
  end

  it "parser stores resume-from on the block call_fields" do
    doc, result = validate(format(two_block_template, provider: "claude_cli"))
    expect(result.valid?).to be(true), result.errors.map(&:message).join("\n")
    revise = doc.processes.first.block("revise")
    expect(revise.type_fields["resume-from"]).to eq("{{draft.session_id}}")
  end

  it "renderer round-trips resume-from" do
    doc, _ = validate(format(two_block_template, provider: "claude_cli"))
    rendered = Prouterd::Config::Renderer.render(doc)
    expect(rendered).to include("resume-from")
  end

  describe "validator: provider gate" do
    it "rejects resume-from on an HTTP-provider iface (no session model)" do
      src = <<~PRC
        router demo
        exit
        secret K
         source env K
        exit
        interface llm m
         provider anthropic
         model claude-X
         auth bearer secret K
        exit
        process p
         block draft
          interface llm m
          prompt "first"
         exit
         block revise
          interface llm m
          prompt "second"
          resume-from "{{draft.session_id}}"
         exit
         route draft revise
        exit
      PRC
      _, result = validate(src)
      expect(result.valid?).to be(false)
      expect(result.errors.map(&:message).join).to match(/`resume-from` only applies to subprocess LLM providers/)
    end

    it "accepts resume-from on a same-provider chain (codex_cli)" do
      _, result = validate(format(two_block_template, provider: "codex_cli"))
      expect(result.valid?).to be(true), result.errors.map(&:message).join("\n")
    end

    it "accepts resume-from on a same-provider chain (claude_cli)" do
      _, result = validate(format(two_block_template, provider: "claude_cli"))
      expect(result.valid?).to be(true), result.errors.map(&:message).join("\n")
    end

    it "rejects resume-from pointing at a non-existent upstream block" do
      src = <<~PRC
        router demo
        exit
        interface llm m
         provider claude_cli
         model some-model
        exit
        process p
         block revise
          interface llm m
          prompt "second"
          resume-from "{{ghost.session_id}}"
         exit
        exit
      PRC
      _, result = validate(src)
      expect(result.errors.map(&:message).join).to include("references unknown block 'ghost'")
    end

    it "rejects resume-from pointing at a non-LLM upstream block" do
      src = <<~PRC
        router demo
        exit
        interface llm m
         provider claude_cli
         model some-model
        exit
        interface docker img
         image foo
        exit
        process p
         block worker
          interface docker img
         exit
         block revise
          interface llm m
          prompt "p"
          resume-from "{{worker.session_id}}"
         exit
         route worker revise
        exit
      PRC
      _, result = validate(src)
      expect(result.errors.map(&:message).join).to match(/is not an LLM block/)
    end

    it "rejects resume-from when upstream and downstream LLMs use different providers" do
      src = <<~PRC
        router demo
        exit
        interface llm one
         provider codex_cli
         model some-model
        exit
        interface llm two
         provider claude_cli
         model other-model
        exit
        process p
         block draft
          interface llm one
          prompt "first"
         exit
         block revise
          interface llm two
          prompt "second"
          resume-from "{{draft.session_id}}"
         exit
         route draft revise
        exit
      PRC
      _, result = validate(src)
      expect(result.errors.map(&:message).join).to match(/provider mismatch/)
    end

    it "tolerates a block whose downstream llm iface vanished from the doc (defensive &.)" do
      src = <<~PRC
        router demo
        exit
        interface llm m
         provider claude_cli
         model some-model
        exit
        process p
         block revise
          interface llm m
          prompt "p"
          resume-from "literal-uuid"
         exit
        exit
      PRC
      doc = parse(src)
      # Strip the iface that 'revise' references AFTER parse so the
      # check_resume_from method's iface lookup returns nil.
      doc.interfaces.clear
      result = Prouterd::Config::Validator.validate(doc)
      # Other validator paths will flag the missing iface; we just want
      # check_resume_from itself NOT to NoMethodError on the &. chain.
      expect { result }.not_to raise_error
    end

    it "tolerates an upstream block whose iface vanished from the doc (defensive &.)" do
      src = <<~PRC
        router demo
        exit
        interface llm m
         provider claude_cli
         model some-model
        exit
        interface llm n
         provider claude_cli
         model some-model
        exit
        process p
         block draft
          interface llm n
          prompt "first"
         exit
         block revise
          interface llm m
          prompt "second"
          resume-from "{{draft.session_id}}"
         exit
         route draft revise
        exit
      PRC
      doc = parse(src)
      # Strip the upstream block's iface so upstream_iface lookup returns nil
      doc.interfaces.reject! { |i| i.name == "n" }
      result = Prouterd::Config::Validator.validate(doc)
      expect { result }.not_to raise_error
    end

    it "accepts a non-{{...}} literal resume-from value (treated as runtime opaque)" do
      src = <<~PRC
        router demo
        exit
        interface llm m
         provider claude_cli
         model some-model
        exit
        process p
         block revise
          interface llm m
          prompt "p"
          resume-from "literal-uuid"
         exit
        exit
      PRC
      _, result = validate(src)
      expect(result.valid?).to be(true), result.errors.map(&:message).join("\n")
    end
  end
end
