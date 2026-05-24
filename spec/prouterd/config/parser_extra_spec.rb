require "spec_helper"

# Targets uncovered branches in lib/prouterd/config/parser.rb.
# All tests focus on error paths (most parsing happy paths are
# already covered by parser_spec.rb / merge_parser_spec.rb).
RSpec.describe Prouterd::Config::Parser do
  def parse(src, base_dir: nil)
    described_class.parse(Prouterd::Config::Lexer.tokenize(src), base_dir: base_dir)
  end

  PARSER_EXTRA_IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
    interface docker img2
     image alpine:2
    exit
  PRC

  def parse_with_ifaces(src)
    parse(PARSER_EXTRA_IFACES + src)
  end

  # ----- top-level / router -----

  describe "top-level error branches" do
    it "rejects bare 'exit' at top level" do
      expect { parse("exit\n") }
        .to raise_error(Prouterd::Config::ParseError, /unexpected 'exit' at top level/)
    end

    it "rejects unknown top-level directive" do
      expect { parse("garbage\n") }
        .to raise_error(Prouterd::Config::ParseError, /unknown top-level directive 'garbage'/)
    end
  end

  # ----- secret -----

  describe "secret error branches" do
    it "errors on unknown directive inside secret" do
      expect { parse(<<~SRC) }
        secret X
         color red
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'color' in secret/)
    end

    it "treats env source value with bad env-var name as error" do
      expect { parse(<<~SRC) }
        secret X
         source env lowercase
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid env variable/)
    end

    it "parses a file-sourced secret with a quoted path" do
      doc = parse(<<~SRC)
        secret X
         source file "/etc/foo.key"
        exit
      SRC
      expect(doc.secrets.first.source_type).to eq("file")
      expect(doc.secrets.first.source_value).to eq("/etc/foo.key")
    end

    it "errors when source kind is correct but extra tokens given" do
      expect { parse(<<~SRC) }
        secret X
         source env A B
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'source env <ref>'/)
    end
  end

  # ----- policy -----

  describe "policy error branches" do
    it "errors on unknown directive inside policy" do
      expect { parse(<<~SRC) }
        policy p
         color red
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'color' in policy/)
    end

    it "errors on unknown retry field" do
      expect { parse(<<~SRC) }
        policy p
         retry whatever 1
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown retry field 'whatever'/)
    end

    it "errors when retry attempts < 1" do
      expect { parse(<<~SRC) }
        policy p
         retry attempts 0
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /retry attempts must be >= 1/)
    end

    it "parses retry when condition (covers parse_match_at offset path)" do
      doc = parse(<<~SRC)
        policy p
         retry when output.score gt 70
        exit
      SRC
      m = doc.policies.first.retry_when_matches.first
      expect(m.path).to eq("output.score")
      expect(m.operator).to eq("gt")
      expect(m.values).to eq([70])
    end

    it "parses retry stop-on condition" do
      doc = parse(<<~SRC)
        policy p
         retry stop-on run.cost_usd gt 5.0
        exit
      SRC
      m = doc.policies.first.retry_stop_matches.first
      expect(m.path).to eq("run.cost_usd")
      expect(m.operator).to eq("gt")
    end
  end

  # ----- queue -----

  describe "queue error branches" do
    it "errors on unknown directive in queue" do
      expect { parse(<<~SRC) }
        queue q
         color red
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'color' in queue/)
    end

    it "errors when concurrency < 1" do
      expect { parse(<<~SRC) }
        queue q
         concurrency 0
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /concurrency must be >= 1/)
    end

    it "parses timeout on queue (covers timeout branch in apply_queue_field)" do
      doc = parse(<<~SRC)
        queue q
         concurrency 1
         timeout 5m
        exit
      SRC
      expect(doc.queues.first.timeout_ms).to eq(300_000)
    end
  end

  # ----- interface header and body -----

  describe "interface header error branches" do
    it "errors on invalid interface type" do
      expect { parse(<<~SRC) }
        interface nonexistent foo
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid interface type 'nonexistent'/)
    end
  end

  describe "interface body error branches" do
    it "rejects extra tokens after 'shutdown' on an interface" do
      expect { parse(<<~SRC) }
        interface docker x
         image y
         shutdown extra
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'shutdown'/)
    end

    it "rejects 'no foo' where foo != shutdown on interface" do
      expect { parse(<<~SRC) }
        interface docker x
         image y
         no garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /only 'no shutdown' is supported/)
    end

    it "accepts bare 'shutdown' on interface" do
      doc = parse(<<~SRC)
        interface docker x
         image y
         shutdown
        exit
      SRC
      expect(doc.interfaces.first.shutdown).to eq(true)
    end
  end

  # ----- apply_field_kind branches -----

  describe "field kind error branches" do
    it "rejects :path field not starting with /" do
      expect { parse(<<~SRC) }
        interface webhook w
         path leads
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, %r{path must start with '/'})
    end

    it "rejects invalid value for :enum field" do
      expect { parse(<<~SRC) }
        interface docker x
         image y
         pull yolo
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid pull 'yolo'/)
    end

    it "rejects invalid auth scheme" do
      expect { parse(<<~SRC) }
        interface webhook w
         path /x
         auth basic secret TOKEN
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid auth scheme 'basic'/)
    end

    it "rejects missing 'secret' keyword in auth directive" do
      expect { parse(<<~SRC) }
        interface webhook w
         path /x
         auth bearer token TOKEN
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'secret' keyword/)
    end

    it "parses hmac-sha256 signature directive" do
      doc = parse(<<~SRC)
        secret HMAC_KEY
         source env HMAC_KEY
        exit
        interface webhook w
         path /x
         hmac-sha256 secret HMAC_KEY header "X-Sig"
        exit
      SRC
      hmac = doc.interfaces.first.type_fields["hmac-sha256"]
      expect(hmac.algorithm).to eq("sha256")
      expect(hmac.header).to eq("x-sig")
      expect(hmac.secret_name).to eq("HMAC_KEY")
    end

    it "rejects hmac directive with missing 'secret' keyword" do
      expect { parse(<<~SRC) }
        interface webhook w
         path /x
         hmac-sha256 nokey HMAC_KEY header "X-Sig"
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'secret' in hmac-sha256/)
    end

    it "rejects hmac directive with missing 'header' keyword" do
      expect { parse(<<~SRC) }
        interface webhook w
         path /x
         hmac-sha256 secret HMAC_KEY hd "X-Sig"
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'header' in hmac-sha256/)
    end

    it "parses :env_pair (env KEY VALUE)" do
      doc = parse(<<~SRC)
        interface shell s
         env FOO bar
         env BAZ "qux quux"
        exit
      SRC
      expect(doc.interfaces.first.type_fields["env"]).to eq("FOO" => "bar", "BAZ" => "qux quux")
    end

    it "rejects invalid mcp server kind" do
      expect { parse(<<~SRC) }
        interface mcp m
         server unknown "spec"
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid server kind 'unknown'/)
    end

    it "parses :mcp_server" do
      doc = parse(<<~SRC)
        interface mcp m
         server npx "@org/srv"
        exit
      SRC
      expect(doc.interfaces.first.type_fields["server"])
        .to eq("kind" => "npx", "spec" => "@org/srv")
    end

    it "parses :secret_ref accumulating list" do
      doc = parse(<<~SRC)
        secret A
         source env A
        exit
        secret B
         source env B
        exit
        interface mcp m
         server npx "x"
         secret A
         secret B
        exit
      SRC
      expect(doc.interfaces.last.type_fields["secret"]).to eq(%w[A B])
    end

    it "parses :env_forward accumulating list" do
      doc = parse(<<~SRC)
        interface llm l
         provider codex_cli
         model gpt-x
         env-forward PATH
         env-forward HOME
        exit
      SRC
      expect(doc.interfaces.first.type_fields["env-forward"]).to eq(%w[PATH HOME])
    end

    it "parses :duration_ms field" do
      doc = parse(<<~SRC)
        interface mcp m
         server npx "x"
         timeout-tool-call 30s
        exit
      SRC
      expect(doc.interfaces.first.type_fields["timeout-tool-call"]).to eq(30_000)
    end

    it "rejects when plugin declares an unknown :kind (defensive else)" do
      # Inject a fake plugin with an unknown kind to drive the
      # apply_field_kind else branch (parse path).
      fake_plugin = Class.new(Prouterd::Iface::Plugin) do
        type "fake_for_kind_else"
        direction :outbound
        field :weird, kind: :totally_unknown_kind
        call_field :nope, kind: :totally_unknown_kind
        caller "Object"
      end
      Prouterd::Iface::Registry.register!(fake_plugin)
      begin
        expect {
          parse(<<~SRC)
            interface fake_for_kind_else f
             weird whatever
            exit
          SRC
        }.to raise_error(Prouterd::Config::ParseError, /unknown kind :totally_unknown_kind/)
      ensure
        Prouterd::Iface::Registry.instance_variable_get(:@store)&.delete("fake_for_kind_else")
        # registry.send(:store).delete("fake_for_kind_else") if defined?(Prouterd::Iface::Registry)
      end
    end
  end

  # ----- process body branches -----

  describe "process body error branches" do
    it "rejects unknown directive in process" do
      expect { parse(<<~SRC) }
        process p
         garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in process/)
    end

    it "rejects bare 'description' without text" do
      expect { parse(<<~SRC) }
        process p
         description
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /description requires text/)
    end

    it "rejects process 'shutdown extra' with too many tokens" do
      expect { parse(<<~SRC) }
        process p
         shutdown unrelated
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'shutdown'/)
    end

    it "rejects process 'no foo' where foo != shutdown" do
      expect { parse(<<~SRC) }
        process p
         no garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /only 'no shutdown' is supported/)
    end

    it "accepts process 'shutdown' bare and 'no shutdown'" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         shutdown
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(doc.processes.first.shutdown).to eq(true)
    end

    it "accepts thread-id template" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         thread-id "{{event.ticket}}"
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(doc.processes.first.thread_id_template).to eq("{{event.ticket}}")
    end

    it "accepts process timeout" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         timeout 10m
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(doc.processes.first.timeout_ms).to eq(600_000)
    end
  end

  # ----- parallel and merge -----

  describe "parallel error branches" do
    it "rejects duplicate name (block already exists)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block g
          interface docker img1
         exit
         parallel g
          block c
           interface docker img1
          exit
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /name 'g' is already declared/)
    end

    it "rejects unknown directive inside parallel" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         parallel g
          garbage
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' inside parallel/)
    end

    it "rejects duplicate block name inside parallel (same as sibling)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         parallel g
          block a
           interface docker img1
          exit
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /duplicate block 'a' inside parallel/)
    end

    it "rejects invalid join-strategy value" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         parallel g
          join-strategy bogus
          block a
           interface docker img1
          exit
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid join-strategy 'bogus'/)
    end
  end

  describe "merge error branches" do
    it "rejects merge with no members (parser-level: missing `from`)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         merge m
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /must list at least one member/)
    end

    it "rejects unknown directive inside merge" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         merge m
          from a
          garbage
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' inside merge/)
    end

    it "rejects invalid member name in `from` (not an identifier)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         merge m
          from 99bad
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid block name '99bad'/)
    end

    it "rejects merge that includes itself in `from`" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         merge m
          from m
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /cannot include itself/)
    end

    it "rejects duplicate member in `from`" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         merge m
          from a, b, a
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /duplicate member 'a' in merge 'm'/)
    end

    it "rejects invalid merge strategy" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         merge m
          from a
          strategy bogus
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid strategy 'bogus'/)
    end
  end

  # ----- block body branches -----

  describe "block body error branches" do
    it "rejects malformed retry on block" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          retry one two three
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /retry <policy_name>/)
    end

    it "accepts long-form `retry policy <name>` on block" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          retry policy r
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.retry_policy_name).to eq("r")
    end

    it "accepts agentic off" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          agentic off
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.agentic).to eq(false)
    end

    it "rejects invalid agentic value" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          agentic maybe
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid agentic value 'maybe'/)
    end

    it "rejects invalid tool name in allowed-tools" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          allowed-tools  good, 99bad
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid tool name '99bad'/)
    end

    it "accepts namespaced tool name (mcp.tool)" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          allowed-tools  atlassian.search_issues
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.allowed_tools).to eq(%w[atlassian.search_issues])
    end

    it "parses mcp <iface, ...> on block" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          mcp atlassian, sentry
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.mcp_refs).to eq(%w[atlassian sentry])
    end

    it "rejects invalid mcp iface name" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          mcp 99bad
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid mcp interface name '99bad'/)
    end

    it "rejects tool-call-limit < 1" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          tool-call-limit 0
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /tool-call-limit must be >= 1/)
    end

    it "accepts max-cost-usd" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          max-cost-usd 2.5
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.max_cost_usd).to eq(2.5)
    end

    it "rejects max-cost-usd <= 0" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          max-cost-usd 0
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /max-cost-usd must be > 0/)
    end

    it "rejects malformed fan-out" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          fan-out into other
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /syntax: fan-out from/)
    end

    it "rejects two fan-out directives on one block" do
      expect { parse_with_ifaces(<<~SRC) }
        process other
         block z
          interface docker img1
         exit
        exit
        process p
         block b
          interface docker img1
          fan-out from x into other
          fan-out from y into other
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /already has a fan-out/)
    end

    it "rejects two pause directives on one block" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          pause "a"
          pause "b"
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /already has a `pause` directive/)
    end

    it "rejects enable with extra tokens" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          enable extra
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'enable'/)
    end

    it "accepts disable" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          disable
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.shutdown).to eq(true)
    end

    it "accepts shutdown bare on block" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          shutdown
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.shutdown).to eq(true)
    end

    it "rejects 'no garbage' on block" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          no garbage
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /only 'no shutdown' is supported/)
    end

    it "accepts 'no shutdown' on block" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          no shutdown
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.shutdown).to eq(false)
    end

    it "rejects unknown call-field when interface has none of that name" do
      # docker iface has only `command` call-field; `prompt` is from llm.
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          prompt "x"
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'prompt' in block/)
    end

    it "rejects per-call directive without preceding `interface` reference" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          command "echo"
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /did you forget `interface/)
    end

    it "rejects two interface directives on one block" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          interface docker img2
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /already references/)
    end

    it "rejects interface ref to an unknown type at the block" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface fakething whatever
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid interface type 'fakething'/)
    end

    it "rejects interface ref to inbound plugin (webhook)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface webhook somewh
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /must reference a block-callable outbound interface/)
    end

    it "rejects interface ref to runtime-only outbound (mcp)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface mcp foo
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /runtime-only/)
    end
  end

  # ----- file-form call-fields -----

  describe "call-field file form (extra cases)" do
    require "tmpdir"

    let(:tmpdir) { Dir.mktmpdir("prc-parser-extra-") }
    after { FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir) }

    it "errors when permission denied (SystemCallError other than ENOENT)" do
      path = File.join(tmpdir, "secret.md")
      File.write(path, "x")
      File.chmod(0o000, path)
      begin
        expect {
          parse(<<~SRC, base_dir: tmpdir)
            interface llm chat
             provider anthropic
             model claude-haiku-4-5-20251001
            exit
            process p
             block b
              interface llm chat
              prompt file "secret.md"
             exit
            exit
          SRC
        }.to raise_error(Prouterd::Config::ParseError, /cannot read prompt file/)
      ensure
        File.chmod(0o644, path)
      end
    end

    it "call_field_file_form? returns false when next token is not 'file'" do
      # Cover the `tokens[1].value == 'file'` branch returning false.
      doc = parse(<<~SRC)
        interface llm chat
         provider anthropic
         model claude-haiku-4-5-20251001
        exit
        process p
         block b
          interface llm chat
          prompt "literal value"
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.type_fields["prompt"]).to eq("literal value")
    end
  end

  # ----- artifact input -----

  describe "artifact input error branches" do
    def parse_block(body)
      parse_with_ifaces(<<~SRC).processes.first.blocks.first
        process p
         block b
          interface docker img1
        #{body.lines.map { |l| "  #{l}" }.join}
         exit
        exit
      SRC
    end

    it "rejects malformed from <block>.<relpath> with no extension" do
      expect { parse_block("input from train_only\n") }
        .to raise_error(Prouterd::Config::ParseError, /from <block>.<relpath>/)
    end

    it "rejects invalid from-block name (not an identifier)" do
      expect { parse_block("input from 99bad.x\n") }
        .to raise_error(Prouterd::Config::ParseError, /invalid block name '99bad'/)
    end

    it "rejects absolute artifact path" do
      expect { parse_block("input from train./etc\n") }
        .to raise_error(Prouterd::Config::ParseError, /invalid artifact path '\/etc'/)
    end
  end

  # ----- process route body -----

  describe "process route body error branches" do
    it "rejects unknown directive in route body" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x eq 1
          garbage
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in route body/)
    end

    it "rejects invalid on-failure value" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          on-failure dance
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid on-failure 'dance'/)
    end

    it "accepts on-failure continue" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          on-failure continue
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.on_failure).to eq("continue")
    end

    it "accepts shutdown / no shutdown in route body" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          shutdown
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.shutdown).to eq(true)
    end

    it "rejects route body 'no garbage'" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x eq 1
          no garbage
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /only 'no shutdown' is supported/)
    end

    it "accepts route body 'no shutdown'" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          no shutdown
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.shutdown).to eq(false)
    end

    it "rejects route body 'shutdown garbage'" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          shutdown garbage
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'shutdown'/)
    end
  end

  # ----- global route -----

  describe "global route error branches" do
    it "rejects unknown directive in global route body" do
      expect { parse(<<~SRC) }
        route interface i process p
         garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in global route/)
    end
  end

  # ----- contract -----

  describe "contract error branches" do
    it "rejects unknown directive in contract" do
      expect { parse(<<~SRC) }
        contract c
         garbage x
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in contract/)
    end

    it "rejects malformed 'on' directive (missing 'violation')" do
      expect { parse(<<~SRC) }
        contract c
         on foo retry
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /syntax: on violation/)
    end

    it "errors when min lacks a number" do
      expect { parse(<<~SRC) }
        contract c
         require x min
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected value: min/)
    end

    it "parses 'length' constraint" do
      doc = parse(<<~SRC)
        contract c
         require x length 4
        exit
      SRC
      expect(doc.contracts.first.requirements.first.length).to eq(4)
    end

    it "parses min-length / max-length constraints" do
      doc = parse(<<~SRC)
        contract c
         require x min-length 1 max-length 10
        exit
      SRC
      req = doc.contracts.first.requirements.first
      expect(req.min_length).to eq(1)
      expect(req.max_length).to eq(10)
    end

    it "parses pattern constraint" do
      doc = parse(<<~SRC)
        contract c
         require x pattern "^A.*"
        exit
      SRC
      expect(doc.contracts.first.requirements.first.pattern).to eq("^A.*")
    end

    it "parses format constraint" do
      doc = parse(<<~SRC)
        contract c
         require x format email
        exit
      SRC
      expect(doc.contracts.first.requirements.first.format).to eq("email")
    end

    it "rejects invalid format" do
      expect { parse(<<~SRC) }
        contract c
         require x format whatever
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid format 'whatever'/)
    end

    it "errors when 'in' has no values" do
      expect { parse(<<~SRC) }
        contract c
         require x in
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /'in' requires at least one value/)
    end

    it "rejects non-integer min-length" do
      expect { parse(<<~SRC) }
        contract c
         require x min-length 1.5
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected non-negative integer for min-length/)
    end

    it "accepts float min/max constraints" do
      doc = parse(<<~SRC)
        contract c
         require x min 1.5 max 9.5
        exit
      SRC
      req = doc.contracts.first.requirements.first
      expect(req.min).to eq(1.5)
      expect(req.max).to eq(9.5)
    end

    it "rejects non-numeric min" do
      expect { parse(<<~SRC) }
        contract c
         require x min nope
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected number for min/)
    end
  end

  # ----- tool -----

  describe "tool error branches" do
    it "rejects bare description in tool" do
      expect { parse(<<~SRC) }
        tool t
         description
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /description requires text/)
    end

    it "rejects invalid arg name" do
      expect { parse(<<~SRC) }
        tool t
         args good, 99bad
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid arg name '99bad'/)
    end

    it "rejects duplicate args" do
      expect { parse(<<~SRC) }
        tool t
         args a, b, a
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /duplicate arg name/)
    end

    it "rejects malformed implementation" do
      expect { parse(<<~SRC) }
        tool t
         implementation interface http x get
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /syntax: implementation interface/)
    end

    it "rejects unknown directive in tool" do
      expect { parse(<<~SRC) }
        tool t
         garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in tool/)
    end
  end

  # ----- shell_tool -----

  describe "shell_tool error / accept branches" do
    it "rejects duplicate name (collides with declared interface)" do
      expect { parse(<<~SRC) }
        interface shell foo
        exit
        shell_tool foo
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /name 'foo' is already declared/)
    end

    it "rejects bare description in shell_tool" do
      expect { parse(<<~SRC) }
        shell_tool t
         description
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /description requires text/)
    end

    it "rejects invalid arg in shell_tool" do
      expect { parse(<<~SRC) }
        shell_tool t
         args good, 99bad
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid arg name '99bad'/)
    end

    it "accepts exec directive in shell_tool" do
      doc = parse(<<~SRC)
        shell_tool t
         description "do thing"
         args x
         exec "do.sh"
         cwd /opt/t
        exit
      SRC
      expect(doc.interfaces.first.type).to eq("shell")
      expect(doc.interfaces.first.type_fields["cwd"]).to eq("/opt/t")
    end

    it "rejects unknown directive in shell_tool" do
      expect { parse(<<~SRC) }
        shell_tool t
         garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in shell_tool/)
    end
  end

  # ----- prices -----

  describe "prices error branches" do
    it "rejects unknown directive in prices" do
      expect { parse(<<~SRC) }
        prices anthropic
         garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in prices/)
    end

    it "rejects malformed model line" do
      expect { parse(<<~SRC) }
        prices anthropic
         model x 1 1
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /syntax: model <name> in/)
    end
  end

  # ----- fan-out body (map / dedupe / rate-limit) -----

  describe "fan-out body" do
    def parse_fan_out(body)
      doc = parse_with_ifaces(<<~SRC)
        process other
         block z
          interface docker img1
         exit
        exit
        process p
         block b
          interface docker img1
          fan-out from items into other
        #{body.lines.map { |l| "   #{l}" }.join}
          exit
         exit
        exit
      SRC
      doc.processes.last.blocks.first
    end

    it "parses map with filter starts-with strip-prefix" do
      block = parse_fan_out(<<~BODY)
        map child from items filter starts-with("PRE-") strip-prefix
      BODY
      m = block.fan_out_maps.first
      expect(m["name"]).to eq("child")
      expect(m["from"]).to eq("items")
      expect(m["filter_prefix"]).to eq("PRE-")
      expect(m["strip_prefix"]).to eq(true)
    end

    it "parses map without filter" do
      block = parse_fan_out(<<~BODY)
        map child from items
      BODY
      expect(block.fan_out_maps.first["name"]).to eq("child")
      expect(block.fan_out_maps.first["filter_prefix"]).to be_nil
    end

    it "rejects malformed map (missing `from`)" do
      expect { parse_fan_out("map child for items\n") }
        .to raise_error(Prouterd::Config::ParseError, /syntax: map <name> from/)
    end

    it "rejects malformed filter syntax" do
      expect { parse_fan_out("map child from items filter foo()\n") }
        .to raise_error(Prouterd::Config::ParseError, /filter starts-with/)
    end

    it "rejects trailing tokens after map" do
      expect { parse_fan_out("map child from items extra\n") }
        .to raise_error(Prouterd::Config::ParseError, /trailing tokens after map/)
    end

    it "rejects duplicate map name" do
      expect {
        parse_fan_out(<<~BODY)
          map a from items
          map a from items
        BODY
      }.to raise_error(Prouterd::Config::ParseError, /duplicate map name 'a'/)
    end

    it "parses dedupe with when prior-run.status clause" do
      block = parse_fan_out(<<~BODY)
        map a from items
        dedupe by id window 5m when prior-run.status eq "success"
      BODY
      expect(block.fan_out_dedupe).to eq(
        "by" => "id", "window_ms" => 300_000, "when_status" => "success"
      )
    end

    it "rejects malformed dedupe (missing 'by' or 'window')" do
      expect { parse_fan_out("dedupe id window 5m\n") }
        .to raise_error(Prouterd::Config::ParseError, /syntax: dedupe by/)
    end

    it "rejects malformed dedupe `when` clause" do
      expect { parse_fan_out(<<~BODY) }
        dedupe by id window 5m garbage prior-run.status eq "ok"
      BODY
        .to raise_error(Prouterd::Config::ParseError, /dedupe `when` clause/)
    end

    it "rejects duplicate dedupe clauses" do
      expect {
        parse_fan_out(<<~BODY)
          dedupe by id window 5m
          dedupe by id window 5m
        BODY
      }.to raise_error(Prouterd::Config::ParseError, /duplicate `dedupe`/)
    end

    it "parses rate-limit" do
      block = parse_fan_out("rate-limit 1/5s\n")
      expect(block.fan_out_rate_limit).to eq("n" => 1, "window_ms" => 5_000)
    end

    it "rejects malformed rate-limit" do
      expect { parse_fan_out("rate-limit garbage\n") }
        .to raise_error(Prouterd::Config::ParseError, /rate-limit must look like/)
    end

    it "rejects rate-limit N < 1" do
      expect { parse_fan_out("rate-limit 0/5s\n") }
        .to raise_error(Prouterd::Config::ParseError, /rate-limit N must be >= 1/)
    end

    it "rejects invalid rate-limit window" do
      expect { parse_fan_out("rate-limit 1/garbage\n") }
        .to raise_error(Prouterd::Config::ParseError, /invalid rate-limit window/)
    end

    it "rejects duplicate rate-limit clauses" do
      expect {
        parse_fan_out(<<~BODY)
          rate-limit 1/5s
          rate-limit 1/5s
        BODY
      }.to raise_error(Prouterd::Config::ParseError, /duplicate `rate-limit`/)
    end

    it "rejects unknown directive in fan-out body" do
      expect {
        parse_fan_out(<<~BODY)
          map a from items
          garbage
        BODY
      }.to raise_error(Prouterd::Config::ParseError, /unknown directive 'garbage' in fan-out/)
    end
  end

  # ----- match expression -----

  describe "match expression branches" do
    it "rejects `in` with empty value list (too few tokens)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x in
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /match <path> in/)
    end

    it "rejects `in` whose values all parse as empty (only commas)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x in ,
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /'in' operator requires at least one value/)
    end

    it "rejects unterminated quoted value in `in` list (split_csv_values)" do
      # split_csv_values runs against the JOINED raw token text after the
      # lexer has already balanced its quotes per token. To reach the
      # parser's own "unterminated string" branch we feed an unbalanced
      # `"` via the lexer's backtick raw form (raw text is preserved
      # verbatim), and craft the rest of the tokens so the joined raw
      # passes through split_csv_values.
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x in `"unclosed`
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /unterminated string in match value list/)
    end

    it "coerces integer/float/bool scalars in match value" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x eq -3
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.matches.first.values).to eq([-3])
    end

    it "coerces float in match value" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x lte 1.5
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.matches.first.values).to eq([1.5])
    end

    it "coerces true/false in match value" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x eq true
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.matches.first.values).to eq([true])
    end

    it "scalar_value returns string verbatim for string tokens" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x eq "123"
         exit
        exit
      SRC
      # quoted "123" stays a string (not coerced to int via scalar_value path).
      expect(doc.processes.first.routes.first.matches.first.values).to eq(["123"])
    end

    it "split_csv_values handles bare comma-separated words and quoted strings" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x in a,b,c
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.matches.first.values).to eq(%w[a b c])
    end
  end

  # ----- traversal helpers -----

  describe "traversal helpers" do
    it "rejects unterminated section (missing 'exit')" do
      expect { parse("process p\n block a\n") }
        .to raise_error(Prouterd::Config::ParseError, /missing 'exit'/)
    end

    it "rejects extra tokens on 'exit' line" do
      expect { parse("process p\nexit garbage\n") }
        .to raise_error(Prouterd::Config::ParseError, /expected 'exit'/)
    end
  end

  # ----- expect_* helpers -----

  describe "expect_* helper failure paths" do
    it "expect_word rejects a string token where a word was expected" do
      # `interface <type> <name>` requires <type> as a word.
      expect { parse("interface \"docker\" name\nexit\n") }
        .to raise_error(Prouterd::Config::ParseError, /expected interface type as bare word/)
    end

    it "expect_identifier rejects an invalid identifier" do
      expect { parse("router 9bad\nexit\n") }
        .to raise_error(Prouterd::Config::ParseError, /invalid router name '9bad'/)
    end

    it "expect_env_name rejects lowercase env names" do
      expect { parse(<<~SRC) }
        secret X
         source env lower
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid env variable/)
    end

    it "expect_integer rejects non-numeric values" do
      expect { parse(<<~SRC) }
        router x
         version one
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected integer for version/)
    end

    it "expect_duration rejects bad duration" do
      expect { parse(<<~SRC) }
        policy p
         timeout garbage
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid timeout:/)
    end

    it "expect_decimal rejects non-numeric value" do
      expect { parse(<<~SRC) }
        prices anthropic
         model x in nope out 1
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected decimal for in price/)
    end

    it "expect_context_path rejects path with hyphens" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match has-dashes eq 1
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /invalid match path/)
    end

    it "expect_artifact_relpath rejects path with .. traversal" do
      expect {
        parse_with_ifaces(<<~SRC)
          process p
           block b
            interface docker img1
            produces ../escape
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /must be a relative path/)
    end
  end

  # ----- vars body -----

  describe "vars body" do
    it "parses a vars body with one entry" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block b
          interface docker img1
          vars
           x "1"
          exit
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.vars).to eq("x" => "1")
    end

    it "rejects malformed vars header (extra tokens)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block b
          interface docker img1
          vars extra
           x "1"
          exit
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /expected 'vars'/)
    end
  end

  # ----- comments / blank lines -----

  describe "comments / blank lines" do
    it "skips comment-only lines (handled by lexer + parser)" do
      doc = parse(<<~SRC)
        ! this is a comment
        # also a comment
        router x
         ! interior comment
         version 1
        exit
      SRC
      expect(doc.router.version).to eq(1)
    end

    it "skips blank lines" do
      doc = parse("\n\nrouter x\nexit\n\n")
      expect(doc.router.name).to eq("x")
    end
  end

  # ----- targeted branch fillers (small corner cases) -----

  describe "targeted branch fillers" do
    it "expands shell_tool without `cwd` (covers the `if body[:cwd]` else)" do
      doc = parse(<<~SRC)
        shell_tool t
         description "x"
         args x
        exit
      SRC
      expect(doc.interfaces.first.type_fields).not_to have_key("cwd")
    end

    it "parallel collides with an existing parallel group name (different process)" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         parallel g
          block a
           interface docker img1
          exit
         exit
         parallel g
          block b
           interface docker img1
          exit
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /name 'g' is already declared/)
    end

    it "merge collides with an existing parallel group name" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block x
          interface docker img1
         exit
         parallel g
          block a
           interface docker img1
          exit
         exit
         merge g
          from x
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /name 'g' is already declared/)
    end

    it "merge collides with an existing merge group name" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         merge g
          from a
         exit
         merge g
          from b
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /name 'g' is already declared/)
    end

    it "rejects unknown call-field on an iface with NO call_fields (cron is inbound; manual has none)" do
      # cron is inbound (no block_callable). Use the manual iface to
      # exercise an outbound iface with empty call_fields list.
      # manual is inbound so unsuitable; instead define a custom plugin
      # to drive the `(no call-fields)` branch.
      fake_plugin = Class.new(Prouterd::Iface::Plugin) do
        type "noargs_outbound"
        direction :outbound
        field :setup, kind: :string
        caller "Object"
      end
      Prouterd::Iface::Registry.register!(fake_plugin)
      begin
        expect {
          parse(<<~SRC)
            interface noargs_outbound n
             setup x
            exit
            process p
             block b
              interface noargs_outbound n
              foo bar
             exit
            exit
          SRC
        }.to raise_error(Prouterd::Config::ParseError, /\(no call-fields\)/)
      ensure
        Prouterd::Iface::Registry.instance_variable_get(:@store)&.delete("noargs_outbound")
      end
    end

    it "rejects an unsupported hmac algorithm via a custom plugin keyword" do
      fake_plugin = Class.new(Prouterd::Iface::Plugin) do
        type "iface_hmac_bad"
        direction :inbound
        field :path, kind: :path, required: true
        field :"hmac-md5", kind: :hmac_signature
      end
      Prouterd::Iface::Registry.register!(fake_plugin)
      begin
        expect {
          parse(<<~SRC)
            interface iface_hmac_bad x
             path /x
             hmac-md5 secret K header "X"
            exit
          SRC
        }.to raise_error(Prouterd::Config::ParseError, /unsupported hmac algorithm 'md5'/)
      ensure
        Prouterd::Iface::Registry.instance_variable_get(:@store)&.delete("iface_hmac_bad")
      end
    end

    it "coerces a boolean 'false' scalar in match value" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x eq false
         exit
        exit
      SRC
      expect(doc.processes.first.routes.first.matches.first.values).to eq([false])
    end

    it "fan-out map filter form: missing closing `)` token" do
      doc = parse_with_ifaces(<<~SRC).processes.last.blocks.first
        process other
         block z
          interface docker img1
         exit
        exit
        process p
         block b
          interface docker img1
          fan-out from items into other
           map child from items filter starts-with("X") strip-prefix
          exit
         exit
        exit
      SRC
      # ensure happy-path coverage of full filter parsing (also covers
      # the strip-prefix tail branch).
      expect(doc.fan_out_maps.first["strip_prefix"]).to be(true)
    end

    it "rejects fan-out map filter with no token after `filter`" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             map child from items filter
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /filter starts-with/)
    end

    it "rejects fan-out map filter without closing `)`" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             map child from items filter starts-with("X"
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /filter starts-with/)
    end

    it "rejects fan-out dedupe with no tokens after the head (line.tokens[1] is nil)" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             dedupe
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /syntax: dedupe by/)
    end

    it "rejects fan-out dedupe with truncated `when` (tokens[7] is nil)" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             dedupe by id window 5m when prior-run.status
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /dedupe `when` clause/)
    end

    it "http block call-field of non-text kind (call_field_file_form? returns false on kind not in [:command, :string])" do
      doc = parse(<<~SRC)
        interface http jira
         base-url "https://x"
        exit
        process p
         block b
          interface http jira
          method GET
          path "/issue"
         exit
        exit
      SRC
      expect(doc.processes.first.blocks.first.type_fields["method"]).to eq("GET")
    end

    it "bare `command` call-field with no value (call_field_file_form? returns false on length<2)" do
      expect {
        parse_with_ifaces(<<~SRC)
          process p
           block b
            interface docker img1
            command
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /expected 'command/)
    end

    it "rejects fan-out map filter with malformed starts-with token shape" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             map child from items filter not-starts-with("X")
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /filter starts-with/)
    end

    it "rejects dedupe with too few tokens (line.tokens[3] is nil — &. else branch)" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             dedupe by id
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /syntax: dedupe by/)
    end

    it "rejects dedupe with bad `when` mid-clause (line.tokens[6] is nil)" do
      expect {
        parse_with_ifaces(<<~SRC)
          process other
           block z
            interface docker img1
           exit
          exit
          process p
           block b
            interface docker img1
            fan-out from items into other
             dedupe by id window 5m when
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /dedupe `when` clause/)
    end

    it "match value handles backslash-escaped char inside quoted CSV value" do
      # Crafts a single string-token value via backtick raw, then a
      # second value to exercise split_csv_values loop including the
      # \\-escape branch when there's no real `"` boundary.
      doc = parse_with_ifaces(<<~'SRC')
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x in `"a\\b","c"`
         exit
        exit
      SRC
      # backslash gets consumed and next char appended verbatim.
      expect(doc.processes.first.routes.first.matches.first.values).to eq(["a\\b", "c"])
    end
  end

  # ----- match operator UNARY (exists) sanity -----

  describe "match unary operator" do
    it "rejects extra tokens after `exists`" do
      expect { parse_with_ifaces(<<~SRC) }
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit
         route a b
          match x exists extra
         exit
        exit
      SRC
        .to raise_error(Prouterd::Config::ParseError, /match <path> exists/)
    end
  end
end
