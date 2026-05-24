require "spec_helper"

# Targets uncovered branches in lib/prouterd/config/renderer.rb.
# Focus is on field-kind emit branches, vars/fan-out/parallel/merge,
# contract / prices / tool rendering, and the quote_string helper.
RSpec.describe Prouterd::Config::Renderer do
  def parse(src, base_dir: nil)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src), base_dir: base_dir)
  end

  def render(src)
    described_class.render(parse(src))
  end

  RENDERER_EXTRA_IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def render_with_ifaces(src)
    described_class.render(parse(RENDERER_EXTRA_IFACES + src))
  end

  describe "render top-level" do
    it "returns empty string for an empty document" do
      doc = Prouterd::Config::AST::Document.new
      expect(described_class.render(doc)).to eq("")
    end
  end

  # ----- secret rendering branches -----

  describe "secret rendering" do
    it "renders a secret without a source line when source_type is nil" do
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      sec = Prouterd::Config::AST::Secret.new(name: "X", line: 2)
      doc.secrets << sec
      out = described_class.render(doc)
      expect(out).to include("secret X\nexit")
      expect(out).not_to match(/^ source/)
    end
  end

  # ----- queue rendering: timeout branch -----

  describe "queue rendering" do
    it "renders a queue with timeout (covers `if queue.timeout_ms` then branch)" do
      out = render(<<~SRC)
        router x
        exit
        queue q
         concurrency 1
         timeout 5m
        exit
      SRC
      expect(out).to include("concurrency 1")
      expect(out).to include("timeout 5m")
    end

    it "renders a queue with no timeout (covers else branch)" do
      out = render(<<~SRC)
        router x
        exit
        queue q
         concurrency 1
        exit
      SRC
      expect(out).to include("concurrency 1")
      expect(out).not_to match(/^ timeout/)
    end
  end

  # ----- interface plugin branches: every field kind -----

  describe "interface rendering: per-kind paths" do
    it "renders :path, :http_method, :auth_bearer, :hmac_signature kinds" do
      out = render(<<~SRC)
        secret HMAC_KEY
         source env HMAC_KEY
        exit
        secret W_TOK
         source env W_TOK
        exit
        interface webhook w
         path /leads
         method PUT
         auth bearer secret W_TOK
         hmac-sha256 secret HMAC_KEY header "x-sig"
        exit
      SRC
      expect(out).to include("path /leads")
      expect(out).to include("method PUT")
      expect(out).to include("auth bearer secret W_TOK")
      expect(out).to include("hmac-sha256 secret HMAC_KEY header x-sig")
    end

    it "renders :enum and :command kinds via docker (command via block call-field)" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img1
         image alpine:1
         pull always
        exit
        process p
         block b
          interface docker img1
          command "/bin/run --safe"
         exit
        exit
      SRC
      expect(out).to include("pull always")
      expect(out).to match(/command [`"]\/bin\/run --safe[`"]/)
    end

    it "renders :env_pair (env KEY VALUE) and :secret_ref / :env_forward on llm iface" do
      out = render(<<~SRC)
        secret OPENAI_KEY
         source env OPENAI_KEY
        exit
        router x
        exit
        interface llm m
         provider codex_cli
         model gpt-x
         env LOGLEVEL debug
         env-forward PATH
         env-forward HOME
         secret OPENAI_KEY
        exit
      SRC
      expect(out).to include("env LOGLEVEL debug")
      expect(out).to include("env-forward PATH")
      expect(out).to include("env-forward HOME")
      expect(out).to include("secret OPENAI_KEY")
    end

    it "renders :mcp_server, :duration_ms kinds" do
      out = render(<<~SRC)
        router x
        exit
        interface mcp m
         server npx "@org/x"
         timeout-tool-call 45s
        exit
      SRC
      expect(out).to include("server npx ")
      expect(out).to match(/server npx [`"]@org\/x[`"]/)
      expect(out).to include("timeout-tool-call 45s")
    end
  end

  # ----- process body rendering branches -----

  describe "process body rendering" do
    it "renders timeout on a process" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         timeout 10m
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(out).to include("timeout 10m")
    end

    it "renders process when description is missing (covers `if process.description` else)" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(out).to include("process p")
      expect(out).not_to match(/^ description/)
    end
  end

  # ----- block rendering: fan-out, vars, agentic, max-cost -----

  describe "block rendering: fan-out variants" do
    it "renders fan-out with map / dedupe / rate-limit body" do
      out = render(<<~SRC)
        router x
        exit
        process p
         block search
          interface docker img1
          fan-out from issues into analyze
           map child from items filter starts-with("X") strip-prefix
           map other from items
           dedupe by id window 5m when prior-run.status eq "success"
           rate-limit 1/5s
          exit
         exit
        exit
        process analyze
         block z
          interface docker img1
         exit
        exit
        interface docker img1
         image alpine:1
        exit
      SRC
      expect(out).to include("fan-out from issues into analyze")
      expect(out).to include("map child from items filter starts-with(")
      expect(out).to include("strip-prefix")
      expect(out).to include("dedupe by id window 5m when prior-run.status eq success")
      expect(out).to include("rate-limit 1/5s")
    end

    it "renders block agentic body with mcp + allowed-tools + tool-call-limit" do
      out = render(<<~SRC)
        router x
        exit
        secret K
         source env K
        exit
        interface mcp atlassian
         server npx "x"
        exit
        interface llm m
         provider anthropic
         model claude-haiku-4-5-20251001
        exit
        process p
         block b
          interface llm m
          prompt "ping"
          agentic on
          mcp atlassian
          allowed-tools atlassian.search
          tool-call-limit 5
          max-cost-usd 2.5
         exit
        exit
      SRC
      expect(out).to include("agentic on")
      expect(out).to include("mcp atlassian")
      expect(out).to include("allowed-tools atlassian.search")
      expect(out).to include("tool-call-limit 5")
      expect(out).to include("max-cost-usd 2.5")
    end

    it "renders a block with a contract reference" do
      out = render(<<~SRC)
        router x
        exit
        contract c
         require x type integer
        exit
        interface docker img1
         image alpine:1
        exit
        process p
         block b
          interface docker img1
          contract c
         exit
        exit
      SRC
      expect(out).to include("contract c")
    end

    it "renders a block with a timeout (covers timeout_ms branch)" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block b
          interface docker img1
          timeout 30s
         exit
        exit
      SRC
      expect(out).to include("timeout 30s")
    end
  end

  # ----- block rendering: pause -----

  describe "block rendering: pause" do
    it "renders a pause block (skips interface branch)" do
      out = render(<<~SRC)
        router x
        exit
        process p
         block approve
          pause "ok?"
         exit
        exit
      SRC
      expect(out).to include('pause "ok?"')
    end
  end

  # ----- parallel/merge group rendering -----

  describe "parallel and merge rendering" do
    it "renders a parallel group with non-default join-strategy" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         parallel g
          join-strategy all-best-effort
          block a
           interface docker img1
          exit
          block b
           interface docker img1
          exit
         exit
        exit
      SRC
      expect(out).to include("parallel g")
      expect(out).to include("join-strategy all-best-effort")
    end

    it "renders a parallel group with default join-strategy (no `join-strategy` line)" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         parallel g
          block a
           interface docker img1
          exit
         exit
        exit
      SRC
      expect(out).to include("parallel g")
      expect(out).not_to match(/join-strategy/)
    end

    it "renders a merge group with custom strategy" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img1
         exit
         merge m
          from a, b
          strategy any
         exit
        exit
      SRC
      expect(out).to include("merge m")
      expect(out).to include("from a, b")
      expect(out).to include("strategy any")
    end

    it "renders a merge group with default strategy (no `strategy` line)" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img1
         exit
         merge m
          from a, b
         exit
        exit
      SRC
      expect(out).to include("from a, b")
      expect(out).not_to match(/^  strategy/)
    end
  end

  # ----- route rendering branches -----

  describe "route rendering" do
    it "renders a route with on-failure continue" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img1
         exit
         route a b
          on-failure continue
         exit
        exit
      SRC
      expect(out).to include("on-failure continue")
    end

    it "renders a route with shutdown true" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img1
         exit
         route a b
          shutdown
         exit
        exit
      SRC
      expect(out).to match(/route a b\n\s+shutdown\n\s+exit/)
    end
  end

  # ----- prices rendering -----

  describe "prices rendering" do
    it "renders multiple model rows in canonical price format" do
      out = render(<<~SRC)
        router x
        exit
        prices anthropic
         model haiku in 0.25 out 1.25
         model opus in 15 out 75
        exit
      SRC
      expect(out).to include("prices anthropic")
      expect(out).to include("model haiku in 0.25 out 1.25")
      expect(out).to include("model opus in 15 out 75")
    end
  end

  # ----- tool rendering -----

  describe "tool rendering" do
    it "renders a tool with all optional + required fields" do
      out = render(<<~SRC)
        router x
        exit
        interface http jira
         base-url "https://x"
        exit
        tool t
         description "look things up"
         args a, b
         implementation interface http jira call get
        exit
      SRC
      expect(out).to include("tool t")
      expect(out).to match(/description "look things up"/)
      expect(out).to include("args a, b")
      expect(out).to include("implementation interface http jira call get")
    end

    it "renders a tool with no description and no args" do
      out = render(<<~SRC)
        router x
        exit
        interface http jira
         base-url "https://x"
        exit
        tool t
         implementation interface http jira call get
        exit
      SRC
      expect(out).to match(/tool t\n implementation/)
    end
  end

  # ----- contract rendering: every constraint kind + on-violation -----

  describe "contract rendering" do
    it "renders every constraint type, format, pattern, length variants and `in` enum" do
      out = render(<<~SRC)
        router x
        exit
        contract c
         require a type integer min 0 max 100
         require b length 5
         require c min-length 1 max-length 10
         require d format email
         require e pattern "^A.*"
         require f in "X","Y","Z"
         optional g type array
         on violation warn
        exit
      SRC
      expect(out).to include("require a type integer min 0 max 100")
      expect(out).to include("require b length 5")
      expect(out).to include("require c min-length 1 max-length 10")
      expect(out).to include("require d format email")
      expect(out).to match(/require e pattern [`"]\^A\.\*[`"]/)
      expect(out).to include('require f in "X","Y","Z"')
      expect(out).to include("optional g type array")
      expect(out).to include("on violation warn")
    end

    it "omits `on violation` line when value is default 'fail'" do
      out = render(<<~SRC)
        router x
        exit
        contract c
         require x type integer
        exit
      SRC
      expect(out).not_to match(/on violation/)
    end
  end

  # ----- render_value branches -----

  describe "render_value" do
    it "renders bool/integer/float scalars without quotes" do
      out = render(<<~SRC)
        router x
        exit
        contract c
         require x in 1,2.5,true,false
        exit
      SRC
      expect(out).to include("require x in 1,2.5,true,false")
    end
  end

  # ----- format_price / quote_string / quote_if_needed branches -----

  describe "format_price and quoting helpers" do
    it "renders a fractional price (non-integer) via the %.4f branch" do
      out = render(<<~SRC)
        router x
        exit
        prices p
         model x in 0.125 out 0.5
        exit
      SRC
      expect(out).to include("model x in 0.125 out 0.5")
    end

    it "quote_string switches to backtick form for command with `\"`" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img
         image x
        exit
        process p
         block b
          interface docker img
          command `echo '{"k":1}'`
         exit
        exit
      SRC
      # Has `"` and `\\` triggers — backtick form.
      expect(out).to match(/command `echo '\{"k":1\}'`/)
    end

    it "quote_string uses double-quotes for text containing backtick" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img
         image x
        exit
        process p
         block b
          interface docker img
          command "use `prouter`"
         exit
        exit
      SRC
      # backtick in text falls back to double-quoted form.
      expect(out).to match(/command "use \\?`prouter\\?`"/)
    end

    it "quote_string uses double-quotes for multi-line text (\\n in value)" do
      # Provide a block command with embedded newline via file form
      # (the only way to inject \n into a value).
      require "tmpdir"
      tmpdir = Dir.mktmpdir("prc-render-extra-")
      begin
        File.write(File.join(tmpdir, "cmd.txt"), "line1\nline2\n")
        src = <<~SRC
          router x
          exit
          interface docker img
           image x
          exit
          process p
           block b
            interface docker img
            command file "cmd.txt"
           exit
          exit
        SRC
        doc = parse(src, base_dir: tmpdir)
        out = described_class.render(doc)
        # multi-line value forces double-quoted form with \n escapes.
        expect(out).to match(/command "line1\\nline2\\n"/)
      ensure
        FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
      end
    end

    it "quote_if_needed quotes a string starting with a digit" do
      out = render(<<~SRC)
        router x
         hostname 01-host
        exit
      SRC
      expect(out).to include('hostname "01-host"')
    end

    it "quote_if_needed leaves non-empty bare word untouched" do
      out = render(<<~SRC)
        router x
         hostname plainhost
        exit
      SRC
      expect(out).to include("hostname plainhost")
    end

    it "quote_if_needed quotes empty string" do
      # Drive via AST since the parser collapses empty descriptions.
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      doc.router.hostname = ""
      out = described_class.render(doc)
      expect(out).to include('hostname ""')
    end

    it "escape_string escapes all special characters (backslash, quote, tab, cr)" do
      out = described_class.send(:new, Prouterd::Config::AST::Document.new)
                            .send(:escape_string, %(a\\b"c\nd\te\rf))
      expect(out).to eq('a\\\\b\\"c\\nd\\te\\rf')
    end
  end

  # ----- skip_value? branches -----

  describe "skip_value? branches" do
    it "skips a field whose value equals the plugin's default (http method GET)" do
      # http :method default is "GET". A block with method GET should
      # NOT render `method GET` because skip_value? drops defaults.
      out = render(<<~SRC)
        router x
        exit
        interface http jira
         base-url "https://x"
        exit
        process p
         block b
          interface http jira
          path "/issue"
         exit
        exit
      SRC
      expect(out).not_to match(/method GET/)
    end
  end

  # ----- targeted branch fillers (AST-built or odd fields) -----

  describe "branch fillers" do
    it "renders a queue with nil concurrency (covers `if queue.concurrency` else)" do
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      doc.queues << Prouterd::Config::AST::Queue.new(name: "q", line: 2)
      out = described_class.render(doc)
      expect(out).to match(/queue q\nexit/)
    end

    it "renders an interface whose type has no plugin (skips the field loop)" do
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      iface = Prouterd::Config::AST::Interface.new(type: "phantom_type", name: "x", line: 2)
      doc.interfaces << iface
      out = described_class.render(doc)
      expect(out).to include("interface phantom_type x")
    end

    it "renders an interface with shutdown=true (covers `iface.shutdown ? shutdown : no shutdown` then)" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img
         image x
         shutdown
        exit
      SRC
      expect(out).to match(/interface docker img\n image x\n shutdown\nexit/)
    end

    it "renders interface body :command kind (via local_repo whitelist)" do
      out = render(<<~SRC)
        router x
        exit
        interface local_repo lr
         root /opt/checkouts
         whitelist vosio/app, vosio/api
        exit
      SRC
      expect(out).to include("root /opt/checkouts")
      expect(out).to match(/whitelist [`"]vosio\/app, vosio\/api[`"]/)
    end

    it "renders a process with thread-id template (covers `if process.thread_id_template`)" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         thread-id "{{event.k}}"
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(out).to include('thread-id "{{event.k}}"')
    end

    it "renders a block whose ref-plugin lookup returns nil (covers `if plugin` else in render_block)" do
      # AST-built block with an interface_ref to an unknown type.
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      process = Prouterd::Config::AST::Process.new(name: "p", line: 2)
      block = Prouterd::Config::AST::Block.new(name: "b", line: 3)
      block.interface_ref = Prouterd::Config::AST::InterfaceRef.new(
        type: "phantom", name: "x", line: 4
      )
      process.blocks << block
      doc.processes << process
      out = described_class.render(doc)
      expect(out).to include("interface phantom x")
    end

    it "renders a fan-out block WITHOUT enrichment lines (covers `enrichment` false)" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img1
         image alpine:1
        exit
        process target
         block z
          interface docker img1
         exit
        exit
        process p
         block b
          interface docker img1
          fan-out from items into target
         exit
        exit
      SRC
      expect(out).to include("fan-out from items into target")
      expect(out).not_to match(/^   map/)
    end

    it "renders fan-out dedupe WITHOUT a when-status (covers else for `when_status`)" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img1
         image alpine:1
        exit
        process target
         block z
          interface docker img1
         exit
        exit
        process p
         block b
          interface docker img1
          fan-out from items into target
           dedupe by id window 5m
          exit
         exit
        exit
      SRC
      expect(out).to include("dedupe by id window 5m")
      expect(out).not_to match(/when prior-run/)
    end

    it "renders fan-out WITHOUT rate-limit (covers `if r` else)" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img1
         image alpine:1
        exit
        process target
         block z
          interface docker img1
         exit
        exit
        process p
         block b
          interface docker img1
          fan-out from items into target
           map child from items
          exit
         exit
        exit
      SRC
      expect(out).to include("map child from items")
      expect(out).not_to match(/rate-limit/)
    end

    it "renders agentic block without mcp_refs and without tool_call_limit" do
      out = render(<<~SRC)
        router x
        exit
        interface llm m
         provider anthropic
         model claude-haiku-4-5-20251001
        exit
        process p
         block b
          interface llm m
          prompt "x"
          agentic on
         exit
        exit
      SRC
      expect(out).to include("agentic on")
      expect(out).not_to match(/^  mcp /)
      expect(out).not_to match(/tool-call-limit/)
    end

    it "renders a block with shutdown=true (block-level `disable` shorthand)" do
      out = render(<<~SRC)
        router x
        exit
        interface docker img1
         image alpine:1
        exit
        process p
         block b
          interface docker img1
          disable
         exit
        exit
      SRC
      expect(out).to include("disable")
    end

    it "renders an http block call-field with non-default :http_method (`method PUT`)" do
      out = render(<<~SRC)
        router x
        exit
        interface http jira
         base-url "https://x"
        exit
        process p
         block b
          interface http jira
          method PUT
          path "/x"
         exit
        exit
      SRC
      expect(out).to include("method PUT")
    end

    it "renders a block call-field :env_pair via a custom plugin" do
      fake_plugin = Class.new(Prouterd::Iface::Plugin) do
        type "renderer_envpair"
        direction :outbound
        field :setup, kind: :string
        call_field :envar, kind: :env_pair
        caller "Object"
      end
      Prouterd::Iface::Registry.register!(fake_plugin)
      begin
        out = render(<<~SRC)
          router x
          exit
          interface renderer_envpair r
           setup x
          exit
          process p
           block b
            interface renderer_envpair r
            envar FOO bar
            envar BAZ qux
           exit
          exit
        SRC
        expect(out).to include("envar FOO bar")
        expect(out).to include("envar BAZ qux")
      ensure
        Prouterd::Iface::Registry.instance_variable_get(:@store)&.delete("renderer_envpair")
      end
    end

    it "renders a tool with no implementation (covers `if impl = tool.implementation` else)" do
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      tool = Prouterd::Config::AST::Tool.new(name: "t", line: 2)
      tool.description = "no impl"
      doc.tools << tool
      out = described_class.render(doc)
      expect(out).to include("tool t")
      expect(out).not_to match(/^ implementation/)
    end

    it "render_value handles a non-scalar value (covers `else` -> value.to_s)" do
      r = described_class.send(:new, Prouterd::Config::AST::Document.new)
      expect(r.send(:render_value, :symbol_value)).to eq("symbol_value")
    end

    it "quote_if_needed returns non-String value unchanged (covers `unless text.is_a?(String)` then)" do
      r = described_class.send(:new, Prouterd::Config::AST::Document.new)
      expect(r.send(:quote_if_needed, 42)).to eq(42)
    end

    it "renders a parallel group with a member name not in process.blocks (covers `next unless child`)" do
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      iface = Prouterd::Config::AST::Interface.new(type: "docker", name: "i", line: 2)
      iface.type_fields["image"] = "alpine:1"
      doc.interfaces << iface
      process = Prouterd::Config::AST::Process.new(name: "p", line: 3)
      group = Prouterd::Config::AST::ParallelGroup.new(name: "g", line: 4)
      # Stage a ghost member name; no matching block on process.blocks.
      group.member_block_names << "ghost"
      process.parallel_groups << group
      # Add the synthesized barrier block (so it's there but no
      # `ghost` member block — render_parallel_group's lookup returns nil).
      barrier = Prouterd::Config::AST::Block.new(name: "g", line: 4)
      barrier.barrier_for = ["ghost"]
      barrier.barrier_kind = :parallel
      process.blocks << barrier
      doc.processes << process
      out = described_class.render(doc)
      expect(out).to include("parallel g")
    end

    it "renders interface body field of unknown kind (case else) via custom plugin" do
      fake_plugin = Class.new(Prouterd::Iface::Plugin) do
        type "renderer_unkkind"
        direction :outbound
        field :weird, kind: :totally_unknown
        caller "Object"
      end
      Prouterd::Iface::Registry.register!(fake_plugin)
      begin
        doc = Prouterd::Config::AST::Document.new
        doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
        iface = Prouterd::Config::AST::Interface.new(type: "renderer_unkkind", name: "n", line: 2)
        iface.type_fields["weird"] = "hello"
        doc.interfaces << iface
        # render should not raise — case falls through to nil and skips
        # emission.
        out = described_class.render(doc)
        expect(out).to include("interface renderer_unkkind n")
      ensure
        Prouterd::Iface::Registry.instance_variable_get(:@store)&.delete("renderer_unkkind")
      end
    end

    it "renders a call-field of unknown kind (case else) via custom plugin" do
      fake_plugin = Class.new(Prouterd::Iface::Plugin) do
        type "renderer_unkcf"
        direction :outbound
        field :setup, kind: :string
        call_field :weird, kind: :totally_unknown
        caller "Object"
      end
      Prouterd::Iface::Registry.register!(fake_plugin)
      begin
        doc = Prouterd::Config::AST::Document.new
        doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
        iface = Prouterd::Config::AST::Interface.new(type: "renderer_unkcf", name: "n", line: 2)
        iface.type_fields["setup"] = "ok"
        doc.interfaces << iface
        process = Prouterd::Config::AST::Process.new(name: "p", line: 3)
        block = Prouterd::Config::AST::Block.new(name: "b", line: 4)
        block.interface_ref = Prouterd::Config::AST::InterfaceRef.new(
          type: "renderer_unkcf", name: "n", line: 5
        )
        block.type_fields["weird"] = "hi"
        process.blocks << block
        doc.processes << process
        out = described_class.render(doc)
        expect(out).to include("interface renderer_unkcf n")
      ensure
        Prouterd::Iface::Registry.instance_variable_get(:@store)&.delete("renderer_unkcf")
      end
    end

    it "renders a process with shutdown=true (`process.shutdown ? shutdown : no shutdown` then)" do
      out = render_with_ifaces(<<~SRC)
        router x
        exit
        process p
         shutdown
         block a
          interface docker img1
         exit
        exit
      SRC
      expect(out).to match(/process p\n shutdown\n/)
    end

    it "renders a block via AST when it has neither pause nor interface_ref (covers if/elsif else)" do
      # Real DSL forbids this, but a synthesized barrier block created
      # outside parallel/merge paths can land here. Drive via AST.
      doc = Prouterd::Config::AST::Document.new
      doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 1)
      process = Prouterd::Config::AST::Process.new(name: "p", line: 2)
      block = Prouterd::Config::AST::Block.new(name: "bare", line: 3)
      process.blocks << block
      doc.processes << process
      out = described_class.render(doc)
      expect(out).to include("block bare")
      expect(out).not_to match(/interface |pause /)
    end

    it "skip_value? returns true for an empty array (responds to empty?)" do
      r = described_class.send(:new, Prouterd::Config::AST::Document.new)
      field = Prouterd::Iface::Plugin::Field.new(
        name: :x, kind: :secret_ref, required: false, enum: nil, default: nil, description: nil
      )
      expect(r.send(:skip_value?, [], field)).to be(true)
    end
  end

  # ----- roundtrips -----

  describe "round-trip" do
    it "roundtrips a contract" do
      src = <<~SRC
        router x
        exit
        contract c
         require x type integer min 0 max 10
         optional y type array
         on violation warn
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips a merge group" do
      src = <<~SRC
        router x
        exit
        interface docker img1
         image alpine:1
        exit
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img1
         exit
         merge m
          from a, b
          strategy any
         exit
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips an mcp interface" do
      src = <<~SRC
        secret JIRA_TOKEN
         source env JIRA_TOKEN
        exit
        router x
        exit
        interface mcp atlassian
         server npx "@atlassian/srv"
         cwd /opt
         env LOG INFO
         secret JIRA_TOKEN
         timeout-tool-call 30s
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips a prices block" do
      src = <<~SRC
        router x
        exit
        prices anthropic
         model haiku in 0.25 out 1.25
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips a webhook with auth+hmac" do
      src = <<~SRC
        secret WEB
         source env WEB
        exit
        secret HMAC_KEY
         source env HMAC_KEY
        exit
        router x
        exit
        interface webhook w
         path /leads
         method POST
         auth bearer secret WEB
         hmac-sha256 secret HMAC_KEY header x-sig
         no shutdown
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips a fan-out with full body" do
      src = <<~SRC
        router x
        exit
        interface docker img1
         image alpine:1
        exit
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
           dedupe by id window 5m when prior-run.status eq "success"
           rate-limit 1/5s
          exit
         exit
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips a tool" do
      src = <<~SRC
        router x
        exit
        interface http jira
         base-url "https://x"
        exit
        tool jira_search
         description "Search"
         args jql, max
         implementation interface http jira call get
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "roundtrips a global route with match" do
      src = <<~SRC
        router x
        exit
        interface webhook leads_in
         path /leads
        exit
        interface docker img
         image x
        exit
        process p
         block b
          interface docker img
         exit
        exit
        route interface leads_in process p
         match event.type eq "lead.created"
        exit
      SRC
      first = render(src)
      expect(described_class.render(parse(first))).to eq(first)
    end
  end
end
