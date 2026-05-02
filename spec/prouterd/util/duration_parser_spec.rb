require "spec_helper"

RSpec.describe Prouterd::Util::DurationParser do
  describe ".parse" do
    it "parses milliseconds" do
      expect(described_class.parse("500ms")).to eq(500)
    end

    it "parses seconds" do
      expect(described_class.parse("30s")).to eq(30_000)
    end

    it "parses minutes" do
      expect(described_class.parse("2m")).to eq(120_000)
    end

    it "parses hours" do
      expect(described_class.parse("1h")).to eq(3_600_000)
    end

    it "rejects empty input" do
      expect { described_class.parse("") }.to raise_error(ArgumentError, /invalid duration/)
    end

    it "rejects missing unit" do
      expect { described_class.parse("30") }.to raise_error(ArgumentError, /invalid duration/)
    end

    it "rejects unknown unit" do
      expect { described_class.parse("30days") }.to raise_error(ArgumentError, /invalid duration/)
    end

    it "rejects compound expressions" do
      expect { described_class.parse("1m30s") }.to raise_error(ArgumentError, /invalid duration/)
    end

    it "rejects negative values via regex" do
      expect { described_class.parse("-5s") }.to raise_error(ArgumentError, /invalid duration/)
    end
  end

  describe ".render" do
    it "renders zero" do
      expect(described_class.render(0)).to eq("0s")
    end

    it "renders milliseconds when not divisible" do
      expect(described_class.render(150)).to eq("150ms")
    end

    it "renders seconds when divisible" do
      expect(described_class.render(30_000)).to eq("30s")
    end

    it "renders minutes when divisible" do
      expect(described_class.render(120_000)).to eq("2m")
    end

    it "renders hours when divisible" do
      expect(described_class.render(7_200_000)).to eq("2h")
    end

    it "picks the largest unit available" do
      expect(described_class.render(60_000)).to eq("1m")
      expect(described_class.render(61_000)).to eq("61s")
    end

    it "rejects non-integer or negative" do
      expect { described_class.render(-1) }.to raise_error(ArgumentError)
      expect { described_class.render(1.5) }.to raise_error(ArgumentError)
    end
  end
end
