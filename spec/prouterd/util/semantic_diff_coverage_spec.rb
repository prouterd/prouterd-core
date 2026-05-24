require "spec_helper"

RSpec.describe Prouterd::Util::SemanticDiff do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  describe "Change#to_h_str" do
    it "stringifies kind and preserves name+reason" do
      c = described_class::Change.new(kind: :secret, name: "K", reason: "added")
      expect(c.to_h_str).to eq(kind: "secret", name: "K", reason: "added")
    end
  end

  describe "secret added / removed" do
    it "reports an added secret" do
      left  = parse("router demo\nexit\n")
      right = parse("router demo\nexit\nsecret K\n source env K\nexit\n")
      result = described_class.diff(left, right)
      expect(result.secrets_added.map(&:name)).to eq(["K"])
      expect(result.secrets_removed).to eq([])
    end

    it "reports a removed secret" do
      left  = parse("router demo\nexit\nsecret K\n source env K\nexit\n")
      right = parse("router demo\nexit\n")
      result = described_class.diff(left, right)
      expect(result.secrets_removed.map(&:name)).to eq(["K"])
    end
  end

  describe "policy added / changed / removed" do
    let(:base_with_policy) do
      parse(<<~PRC)
        router demo
        exit
        policy p1
         retry attempts 3
         retry backoff exponential
         retry initial-delay 100ms
         retry max-delay 5s
        exit
      PRC
    end

    it "detects an added policy" do
      base = parse("router demo\nexit\n")
      result = described_class.diff(base, base_with_policy)
      expect(result.policies_added.map(&:name)).to eq(["p1"])
    end

    it "detects a removed policy" do
      base = parse("router demo\nexit\n")
      result = described_class.diff(base_with_policy, base)
      expect(result.policies_removed.map(&:name)).to eq(["p1"])
    end

    it "detects a changed policy (different retry attempts)" do
      altered = parse(<<~PRC)
        router demo
        exit
        policy p1
         retry attempts 5
         retry backoff exponential
         retry initial-delay 100ms
         retry max-delay 5s
        exit
      PRC
      result = described_class.diff(base_with_policy, altered)
      expect(result.policies_changed.map(&:name)).to eq(["p1"])
      expect(result.policies_changed.first.reason).to match(/changed/)
    end
  end

  describe "queue added / changed / removed" do
    let(:base_with_queue) do
      parse(<<~PRC)
        router demo
        exit
        queue q1
         concurrency 3
        exit
      PRC
    end

    it "detects an added queue" do
      base = parse("router demo\nexit\n")
      result = described_class.diff(base, base_with_queue)
      expect(result.queues_added.map(&:name)).to eq(["q1"])
    end

    it "detects a removed queue" do
      base = parse("router demo\nexit\n")
      result = described_class.diff(base_with_queue, base)
      expect(result.queues_removed.map(&:name)).to eq(["q1"])
    end

    it "detects a changed queue (concurrency bumped)" do
      altered = parse(<<~PRC)
        router demo
        exit
        queue q1
         concurrency 5
        exit
      PRC
      result = described_class.diff(base_with_queue, altered)
      expect(result.queues_changed.map(&:name)).to eq(["q1"])
    end
  end

  describe "route removed" do
    it "reports a removed global route" do
      iface = "interface manual cli\n no shutdown\nexit\n" \
              "interface shell host\nexit\n" \
              "process p\n block a\n  interface shell host\n  exec \"true\"\n exit\nexit\n"
      left  = parse("router demo\nexit\n#{iface}route interface cli process p\nexit\n")
      right = parse("router demo\nexit\n#{iface}")
      result = described_class.diff(left, right)
      expect(result.routes_removed.map(&:name)).to include("cli->p")
    end
  end

  describe "common secret (lambda for signature, line 44) and unchanged process" do
    it "considers two identical secrets the same (skip in changed loop) and lambda runs" do
      doc_a = parse(<<~PRC)
        router demo
        exit
        secret K
         source env K
        exit
      PRC
      doc_b = parse(<<~PRC)
        router demo
        exit
        secret K
         source env K
        exit
      PRC
      result = described_class.diff(doc_a, doc_b)
      # Same secret on both sides: lambda invoked, sigs equal, nothing changed.
      expect(result.secrets_added).to eq([])
      expect(result.secrets_removed).to eq([])
    end
  end

  describe "policy_signature with retry_when_matches (line 130)" do
    it "includes retry-when matches in the signature when present" do
      a = parse(<<~PRC)
        router demo
        exit
        policy p1
         retry attempts 3
         retry when error_type eq "timeout"
        exit
      PRC
      b = parse(<<~PRC)
        router demo
        exit
        policy p1
         retry attempts 3
         retry when error_type eq "rate_limit"
        exit
      PRC
      result = described_class.diff(a, b)
      expect(result.policies_changed.map(&:name)).to eq(["p1"])
    end
  end

  describe "process_signature: block with no interface_ref (line 119 &.)" do
    it "compares two processes whose blocks lack an interface_ref without crashing" do
      doc = Prouterd::Config::AST::Document.new
      block = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      block.interface_ref = nil
      process = Prouterd::Config::AST::Process.new(name: "p", line: 0)
      process.blocks << block
      doc.processes << process
      expect { described_class.diff(doc, doc) }.not_to raise_error
    end
  end

  describe "process removed" do
    it "reports a removed process" do
      iface = "interface shell host\nexit\n"
      left  = parse("router demo\nexit\n#{iface}process p\n block a\n  interface shell host\n exit\nexit\n")
      right = parse("router demo\nexit\n#{iface}")
      result = described_class.diff(left, right)
      expect(result.processes_removed.map(&:name)).to eq(["p"])
    end
  end

  describe "summarize_change" do
    it "returns 'shape changed' when sigs have different lengths" do
      expect(described_class.summarize_change([1, 2], [1, 2, 3])).to eq("shape changed")
    end

    it "highlights the first differing field" do
      expect(described_class.summarize_change([1, 2, 3], [1, 9, 3]))
        .to match(/field\[1\].*2.*->.*9/)
    end
  end
end
