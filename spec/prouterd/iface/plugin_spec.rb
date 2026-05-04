require "spec_helper"

RSpec.describe Prouterd::Iface::Plugin do
  describe "Registry" do
    it "registers built-in inbound plugins" do
      expect(Prouterd::Iface::Registry.types).to contain_exactly("webhook", "cron", "manual")
    end

    it "exposes inbound vs outbound classification" do
      expect(Prouterd::Iface::Registry.inbound_types).to contain_exactly("webhook", "cron", "manual")
      expect(Prouterd::Iface::Registry.outbound_types).to be_empty
    end

    it "lookup returns the plugin class for a known type" do
      expect(Prouterd::Iface::Registry.lookup("webhook")).to be(Prouterd::Iface::Plugins::Webhook)
    end

    it "lookup returns nil for an unknown type" do
      expect(Prouterd::Iface::Registry.lookup("nonexistent")).to be_nil
    end
  end

  describe "an end-to-end fake outbound plugin" do
    # Mirrors the test pattern in Runner::Plugin spec — define a plugin
    # in-spec, exercise parser → validator → renderer on it, prove a third
    # party can ship a new interface type without touching core.
    before(:all) do
      printer_class = Class.new(Prouterd::Iface::Plugin) do
        type "test_printer"
        direction :outbound
        field :prefix, kind: :string, required: true,
                       description: "string prepended to every output"
        field :uppercase, kind: :enum, enum: %w[on off], default: "off"
      end
      Prouterd::Iface::Registry.register!(printer_class)
    end

    after(:all) do
      Prouterd::Iface::Registry.store.delete("test_printer")
    end

    it "is discoverable via Registry" do
      plugin = Prouterd::Iface::Registry.lookup("test_printer")
      expect(plugin).not_to be_nil
      expect(plugin.outbound?).to be(true)
    end

    it "parses through the plugin schema with no parser changes" do
      doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(<<~PRC)
          router demo
          exit
          interface test_printer my_printer
           prefix "hello"
           uppercase on
          exit
        PRC
      )
      iface = doc.interfaces.first
      expect(iface.type).to eq("test_printer")
      expect(iface.type_fields["prefix"]).to eq("hello")
      expect(iface.type_fields["uppercase"]).to eq("on")
    end

    it "validator catches missing required fields per plugin schema" do
      doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(<<~PRC)
          router demo
          exit
          interface test_printer broken
          exit
        PRC
      )
      result = Prouterd::Config::Validator.validate(doc)
      expect(result.errors.map(&:message).join("\n"))
        .to match(/interface 'broken' \(test_printer\) missing 'prefix'/)
    end

    it "renderer emits fields in plugin declaration order" do
      doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(<<~PRC)
          router demo
          exit
          interface test_printer p
           prefix "lead-"
           uppercase on
          exit
        PRC
      )
      out = Prouterd::Config::Renderer.render(doc)
      expect(out).to include("interface test_printer p")
      # prefix index < uppercase index in plugin declaration
      prefix_idx = out.index("prefix lead-")
      upper_idx  = out.index("uppercase on")
      expect(prefix_idx).not_to be_nil
      expect(upper_idx).not_to be_nil
      expect(prefix_idx).to be < upper_idx
    end

    it "roundtrip: parse → render → parse is stable" do
      src = <<~PRC
        router demo
        exit

        interface test_printer p
         prefix ">>"
         uppercase on
         no shutdown
        exit
      PRC
      first = Prouterd::Config::Renderer.render(Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src)))
      second = Prouterd::Config::Renderer.render(Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(first)))
      expect(second).to eq(first)
    end
  end
end
