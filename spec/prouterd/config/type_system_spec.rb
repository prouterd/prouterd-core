require "spec_helper"

# What was Phase 12's "block type system" — `type docker { image; ... }`
# subsection inside `block` — is replaced by the unified interface model:
# every block declares `interface <type> <name>` referencing an outbound
# interface (docker/shell/http/llm/...). These tests exercise that flow
# end-to-end: parser → validator → renderer.
RSpec.describe "Block + interface composition" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def validate(prc)
    doc = parse(prc)
    [doc, Prouterd::Config::Validator.validate(doc)]
  end

  describe "parser" do
    it "parses an outbound docker interface and a block referencing it" do
      doc = parse(<<~PRC)
        router x
        exit
        interface docker my_image
         image alpine:1
         pull always
         network off
         user nobody
         memory 512m
         cpu 1
        exit
        process p
         block b
          interface docker my_image
          command "sh -c true"
          timeout 30s
          enable
         exit
        exit
      PRC
      iface = doc.interfaces.first
      expect(iface.type).to eq("docker")
      expect(iface.type_fields["image"]).to eq("alpine:1")
      expect(iface.type_fields["pull"]).to eq("always")
      expect(iface.type_fields["network"]).to eq("off")
      expect(iface.type_fields["user"]).to eq("nobody")
      expect(iface.type_fields["memory"]).to eq("512m")
      expect(iface.type_fields["cpu"]).to eq("1")

      block = doc.processes.first.blocks.first
      expect(block.interface_ref.type).to eq("docker")
      expect(block.interface_ref.name).to eq("my_image")
      expect(block.type_fields["command"]).to eq("sh -c true")
      expect(block.timeout_ms).to eq(30_000)
      expect(block.shutdown).to be(false)
    end

    it "parses an outbound shell interface and a block referencing it" do
      doc = parse(<<~PRC)
        router x
        exit
        interface shell host
         cwd ./blocks/b
         shell /bin/bash
         env DEBUG 1
        exit
        process p
         block b
          interface shell host
          exec "ruby app.rb --flag"
          timeout 10s
          enable
         exit
        exit
      PRC
      iface = doc.interfaces.first
      expect(iface.type).to eq("shell")
      expect(iface.type_fields["cwd"]).to eq("./blocks/b")
      expect(iface.type_fields["shell"]).to eq("/bin/bash")
      expect(iface.type_fields["env"]).to eq("DEBUG" => "1")

      block = doc.processes.first.blocks.first
      expect(block.interface_ref.type).to eq("shell")
      expect(block.type_fields["exec"]).to eq("ruby app.rb --flag")
    end

    it "rejects an unknown interface type at the block reference" do
      expect do
        parse(<<~PRC)
          router x
          exit
          process p
           block b
            interface kubernetes ghost
           exit
          exit
        PRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid interface type 'kubernetes'/)
    end

    it "rejects per-call directives that are not in the interface plugin's call_fields" do
      # `prompt` is an LLM call_field; on a docker block it's a typo.
      expect do
        parse(<<~PRC)
          router x
          exit
          interface docker img1
           image alpine:1
          exit
          process p
           block b
            interface docker img1
            prompt "hi"
           exit
          exit
        PRC
      end.to raise_error(Prouterd::Config::ParseError, /unknown directive 'prompt' in block/)
    end

    it "accepts `retry <name>` shorthand and `retry policy <name>` long form" do
      doc = parse(<<~PRC)
        router x
        exit
        interface docker img1
         image x
        exit
        policy r
         retry attempts 3
         retry backoff fixed
        exit
        process p
         block b
          interface docker img1
          retry r
         exit
        exit
      PRC
      expect(doc.processes.first.blocks.first.retry_policy_name).to eq("r")
    end

    it "accepts enable / disable as block-level shorthand" do
      doc = parse(<<~PRC)
        router x
        exit
        interface docker img1
         image x
        exit
        process p
         block b
          interface docker img1
          disable
         exit
        exit
      PRC
      expect(doc.processes.first.blocks.first.shutdown).to be(true)
    end
  end

  describe "validator" do
    it "rejects an interface declaration without its required fields" do
      _, r = validate(<<~PRC)
        router x
        exit
        interface docker img1
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/\(docker\) missing 'image'/)
    end

    it "rejects a block missing its `interface` directive" do
      _, r = validate(<<~PRC)
        router x
        exit
        process p
         block b
         exit
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/missing `interface <type> <name>`/)
    end
  end

  describe "renderer" do
    it "roundtrips block + interface composition via parse → render → parse" do
      src = <<~PRC
        router x
        exit
        interface shell host
         shell /bin/bash
         cwd ./b
        exit
        process p
         block b
          interface shell host
          exec "ruby app.rb"
          timeout 10s
          enable
         exit
        exit
      PRC
      rendered = Prouterd::Config::Renderer.render(parse(src))
      expect(rendered).to include("interface shell host")
      expect(rendered).to include("interface shell host") # in block body too
      expect(rendered).to include('exec "ruby app.rb"')
      expect(rendered).to include("enable")
      reparsed = parse(rendered)
      block = reparsed.processes.first.blocks.first
      expect(block.interface_ref.type).to eq("shell")
      expect(block.type_fields["exec"]).to eq("ruby app.rb")
    end
  end
end
