require "spec_helper"

RSpec.describe Prouterd::Iface::Plugin do
  describe ".direction" do
    it "raises when given an unknown direction" do
      cls = Class.new(described_class) { type "__dir_bad" }
      expect { cls.direction :sideways }
        .to raise_error(/direction must be :inbound or :outbound/)
    end

    it "raises when read before being set" do
      cls = Class.new(described_class) { type "__dir_unset" }
      expect { cls.direction }.to raise_error(/missing `direction/)
    end
  end

  describe ".type_name" do
    it "raises when no `type` was declared" do
      cls = Class.new(described_class)
      expect { cls.type_name }.to raise_error(/missing `type/)
    end
  end

  describe ".block_callable" do
    it "returns false for inbound plugins regardless of @block_callable" do
      cls = Class.new(described_class) do
        type "__bc_in"
        direction :inbound
      end
      cls.block_callable false
      expect(cls.block_callable).to be(false)
      expect(cls.block_callable?).to be(false)
    end

    it "outbound default is true" do
      cls = Class.new(described_class) do
        type "__bc_out_default"
        direction :outbound
      end
      expect(cls.block_callable).to be(true)
    end

    it "outbound + explicit false stays false" do
      cls = Class.new(described_class) do
        type "__bc_out_false"
        direction :outbound
        block_callable false
      end
      expect(cls.block_callable).to be(false)
    end

    it "outbound + explicit true stays true" do
      cls = Class.new(described_class) do
        type "__bc_out_true"
        direction :outbound
        block_callable true
      end
      expect(cls.block_callable).to be(true)
    end
  end

  describe ".caller / .caller_class" do
    it "caller returns nil until set" do
      cls = Class.new(described_class) { type "__cl_unset"; direction :outbound }
      expect(cls.caller).to be_nil
    end

    it "caller_class raises when caller was never set" do
      cls = Class.new(described_class) { type "__cl_unset2"; direction :outbound }
      expect { cls.caller_class }.to raise_error(/missing `caller/)
    end

    it "caller can take a Class and caller_class returns it directly" do
      target = Class.new
      stub_const("TargetCallerClass", target)
      cls = Class.new(described_class) do
        type "__cl_cls"
        direction :outbound
        caller TargetCallerClass
      end
      expect(cls.caller_class).to be(target)
    end

    it "caller can take a String and caller_class resolves it lazily" do
      target = Class.new
      stub_const("StringResolvedCaller", target)
      cls = Class.new(described_class) do
        type "__cl_str"
        direction :outbound
        caller "StringResolvedCaller"
      end
      expect(cls.caller_class).to be(target)
    end
  end

  describe "Field struct" do
    it "exposes dsl_keyword and storage_key derived from the name" do
      f = described_class::Field.new(name: :foo, kind: :string)
      expect(f.dsl_keyword).to eq("foo")
      expect(f.storage_key).to eq("foo")
    end
  end

  describe ".field_for and .call_field_for" do
    it "finds fields by dsl keyword and returns nil for unknown" do
      cls = Class.new(described_class) do
        type "__ff"
        direction :outbound
        field :alpha, kind: :string
        call_field :beta, kind: :string
      end
      expect(cls.field_for("alpha").name).to eq(:alpha)
      expect(cls.field_for("missing")).to be_nil
      expect(cls.call_field_for("beta").name).to eq(:beta)
      expect(cls.call_field_for("missing")).to be_nil
    end
  end

  describe ".validate default" do
    it "is a no-op (returns nil)" do
      cls = Class.new(described_class) { type "__v"; direction :outbound }
      expect(cls.validate(nil, nil, nil)).to be_nil
    end
  end
end
