require "spec_helper"

RSpec.describe Prouterd::Iface::Registry do
  # Build a fresh plugin class with the given type name.
  def make_plugin(name, dir = :outbound)
    Class.new(Prouterd::Iface::Plugin) do
      type name
      direction dir
    end
  end

  describe ".register" do
    it "writes the plugin into the store under its type_name (overwrite allowed)" do
      a = make_plugin("__reg_a")
      b = make_plugin("__reg_a")
      described_class.register(a)
      described_class.register(b)
      expect(described_class.lookup("__reg_a")).to be(b)
    ensure
      described_class.store.delete("__reg_a")
    end
  end

  describe ".register!" do
    it "is idempotent for the same class" do
      a = make_plugin("__reg_b")
      described_class.register!(a)
      expect { described_class.register!(a) }.not_to raise_error
    ensure
      described_class.store.delete("__reg_b")
    end

    it "raises DuplicateError when a different class claims the same type" do
      a = make_plugin("__reg_c")
      b = make_plugin("__reg_c")
      described_class.register!(a)
      expect {
        described_class.register!(b)
      }.to raise_error(described_class::DuplicateError, /already registered/)
    ensure
      described_class.store.delete("__reg_c")
    end
  end

  describe ".lookup!" do
    it "raises UnknownTypeError on missing type" do
      expect {
        described_class.lookup!("never_registered_xyz")
      }.to raise_error(described_class::UnknownTypeError, /no interface plugin registered/)
    end

    it "returns the plugin when present" do
      a = make_plugin("__reg_d")
      described_class.register!(a)
      expect(described_class.lookup!("__reg_d")).to be(a)
    ensure
      described_class.store.delete("__reg_d")
    end
  end

  describe ".all and .each" do
    it "iterates the store via .each with a block" do
      seen = []
      described_class.each { |p| seen << p }
      expect(seen).to include(*described_class.all)
    end

    it "returns an Enumerator when .each is called without a block" do
      result = described_class.each
      expect(result).to respond_to(:each)
      # Comparing against the array form proves it enumerates the store.
      expect(result.to_a).to eq(described_class.all.to_a)
    end
  end

  describe ".clear! and re-registration" do
    it "clears all plugins and types becomes empty until re-registered" do
      saved = described_class.store.dup
      begin
        described_class.clear!
        expect(described_class.types).to eq([])
        expect(described_class.inbound_types).to eq([])
        expect(described_class.outbound_types).to eq([])
      ensure
        # Restore the registry so other specs still see the built-ins.
        described_class.instance_variable_set(:@store, saved)
      end
    end
  end
end
