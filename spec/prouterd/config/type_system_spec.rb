require "spec_helper"

RSpec.describe "Phase 12 block type system" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def validate(prc)
    doc = parse(prc)
    [doc, Prouterd::Config::Validator.validate(doc)]
  end

  describe "parser" do
    it "parses a `type docker` sub-section with all options" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block b
          type docker
           image alpine:1
           command "sh -c true"
           pull always
           network off
           user nobody
           memory 512m
           cpu 1
          exit
          input event.body
          output result
          timeout 30s
          enable
         exit
        exit
      PRC
      block = doc.processes.first.blocks.first
      expect(block.execution_type).to eq("docker")
      expect(block.image).to eq("alpine:1")
      expect(block.command).to eq("sh -c true")
      expect(block.pull).to eq("always")
      expect(block.network).to eq("off")
      expect(block.user).to eq("nobody")
      expect(block.memory).to eq("512m")
      expect(block.cpu).to eq("1")
      expect(block.timeout_ms).to eq(30_000)
      expect(block.shutdown).to be(false)
    end

    it "parses a `type shell` sub-section" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block b
          type shell
           exec "ruby app.rb --flag"
           cwd ./blocks/b
           shell /bin/bash
           env DEBUG 1
          exit
          input event
          output result
          timeout 10s
          enable
         exit
        exit
      PRC
      block = doc.processes.first.blocks.first
      expect(block.execution_type).to eq("shell")
      expect(block.shell?).to be(true)
      expect(block.shell_exec).to eq("ruby app.rb --flag")
      expect(block.shell_cwd).to eq("./blocks/b")
      expect(block.shell_path).to eq("/bin/bash")
      expect(block.shell_env).to eq("DEBUG" => "1")
    end

    it "rejects unknown type" do
      expect do
        parse(<<~PRC)
          router x
          exit
          process p
           block b
            type kubernetes
             image x
            exit
           exit
          exit
        PRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid block type 'kubernetes'/)
    end

    it "still accepts legacy inline form (image directly in block) and infers type docker" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block b
          image alpine:1
          input e
          output r
         exit
        exit
      PRC
      block = doc.processes.first.blocks.first
      expect(block.execution_type).to eq("docker") # auto-inferred
      expect(block.image).to eq("alpine:1")
    end

    it "accepts `retry <name>` shorthand and `retry policy <name>` long form" do
      doc = parse(<<~PRC)
        router x
        exit
        policy r
         retry attempts 3
         retry backoff fixed
        exit
        process p
         block b
          type docker
           image x
          exit
          retry r
          input e
          output o
         exit
        exit
      PRC
      expect(doc.processes.first.blocks.first.retry_policy_name).to eq("r")
    end

    it "accepts enable / disable as block-level shorthand" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block b
          type docker
           image x
          exit
          input e
          output o
          disable
         exit
        exit
      PRC
      expect(doc.processes.first.blocks.first.shutdown).to be(true)
    end
  end

  describe "validator" do
    it "rejects type docker without image" do
      _, r = validate(<<~PRC)
        router x
        exit
        process p
         block b
          type docker
          exit
          input e
          output o
         exit
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/\(type docker\) missing 'image'/)
    end

    it "rejects type shell without exec" do
      _, r = validate(<<~PRC)
        router x
        exit
        process p
         block b
          type shell
          exit
          input e
          output o
         exit
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/\(type shell\) missing 'exec'/)
    end

    it "rejects block with no type at all" do
      _, r = validate(<<~PRC)
        router x
        exit
        process p
         block b
          input e
          output o
         exit
        exit
      PRC
      expect(r.errors.map(&:message).join).to match(/missing 'type' section/)
    end
  end

  describe "renderer" do
    it "emits canonical type sub-section form" do
      original = parse(<<~PRC)
        router x
        exit
        process p
         block b
          type shell
           exec "ruby app.rb"
           cwd ./b
          exit
          input e
          output r
          timeout 10s
          enable
         exit
        exit
      PRC
      rendered = Prouterd::Config::Renderer.render(original)
      expect(rendered).to include("type shell")
      expect(rendered).to include('exec "ruby app.rb"')
      expect(rendered).to include("cwd ./b")
      expect(rendered).to include("enable")
      # roundtrip
      reparsed = parse(rendered)
      block = reparsed.processes.first.blocks.first
      expect(block.execution_type).to eq("shell")
      expect(block.shell_exec).to eq("ruby app.rb")
      expect(block.shell_cwd).to eq("./b")
    end
  end
end
