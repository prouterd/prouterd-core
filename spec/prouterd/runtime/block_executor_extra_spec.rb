require "spec_helper"

RSpec.describe Prouterd::Runtime::BlockExecutor do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
  let(:resolver) { Prouterd::Runtime::EnvSecretResolver.new }
  let(:executor) do
    described_class.new(
      db: db, runs: runs,
      runner: Prouterd::Runner::StubRunner.new,
      artifact_store: Prouterd::Runtime::ArtifactStore.new,
      secret_resolver: resolver,
      events: Prouterd::Events.default,
      logger: Prouterd::NullLogger.new,
      mcp_pool: nil,
      retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
    )
  end
  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  describe "#secret_overlay" do
    it "resolves every declared secret via the resolver and stringifies" do
      ENV["TST_A"] = "alpha"
      doc = parse(<<~PRC)
        router demo
        exit
        secret TST_A
         source env TST_A
        exit
        secret TST_B
         source env TST_NOT_SET
        exit
      PRC
      overlay = executor.secret_overlay(doc)
      expect(overlay["TST_A"]).to eq("alpha")
      expect(overlay["TST_B"]).to eq("")
    ensure
      ENV.delete("TST_A")
    end
  end

  describe "#templated_fields" do
    let(:ctx) { Prouterd::Runtime::Context.new("event" => { "name" => "abc" }) }

    it "returns fields unchanged when input is empty" do
      expect(executor.templated_fields({}, ctx)).to eq({})
    end

    it "renders String values via Templater" do
      result = executor.templated_fields({ "cmd" => "hi {{event.name}}" }, ctx)
      expect(result["cmd"]).to eq("hi abc")
    end

    it "renders String values inside nested Hash" do
      result = executor.templated_fields({ "headers" => { "X" => "{{event.name}}" } }, ctx)
      expect(result["headers"]).to eq("X" => "abc")
    end

    it "passes Hash sub-values through when they are not Strings" do
      result = executor.templated_fields({ "headers" => { "X" => 5 } }, ctx)
      expect(result["headers"]).to eq("X" => 5)
    end

    it "passes non-String / non-Hash values through unchanged" do
      result = executor.templated_fields({ "n" => 42 }, ctx)
      expect(result["n"]).to eq(42)
    end
  end

  describe "#build_env" do
    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        secret API_KEY
         source env TST_API_KEY
        exit
        interface http api
         base-url "https://x"
         auth bearer secret API_KEY
        exit
        process p
         block call
          interface http api
          secret API_KEY
         exit
        exit
      PRC
    end
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:process) { doc.processes.first }
    let(:block) { process.blocks.first }
    let(:iface) { doc.interfaces.find { |i| i.name == "api" } }

    it "includes PROUTER_* env vars" do
      env = executor.build_env(run, process, block, iface, doc, 1)
      expect(env["PROUTER_RUN_ID"]).to eq(run.uid)
      expect(env["PROUTER_PROCESS_NAME"]).to eq("p")
      expect(env["PROUTER_BLOCK_NAME"]).to eq("call")
      expect(env["PROUTER_ATTEMPT"]).to eq("1")
    end

    it "resolves block-declared secrets" do
      ENV["TST_API_KEY"] = "value-x"
      env = executor.build_env(run, process, block, iface, doc, 1)
      expect(env["API_KEY"]).to eq("value-x")
    ensure
      ENV.delete("TST_API_KEY")
    end

    it "logs a warning when a block secret resolves to nil" do
      logger = double
      expect(logger).to receive(:warn) do |msg, **|
        expect(msg).to include("secret resolved to empty value")
      end
      ex = described_class.new(
        db: db, runs: runs, runner: Prouterd::Runner::StubRunner.new,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: resolver,
        events: Prouterd::Events.default,
        logger: logger, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      ENV.delete("TST_API_KEY")
      ex.build_env(run, process, block, iface, doc, 1)
    end

    it "raises TriggerError when a block references an unknown secret" do
      block.secret_names << "GHOST"
      expect {
        executor.build_env(run, process, block, iface, doc, 1)
      }.to raise_error(Prouterd::Runtime::TriggerError, /unknown secret/)
    end
  end

  describe "#accumulate_run_usage" do
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }

    it "no-ops for non-Hash output_json" do
      expect { executor.accumulate_run_usage(run, "not a hash") }.not_to raise_error
      expect(runs.get_run(run.id).tokens_in).to eq(0)
    end

    it "no-ops when usage is not a Hash" do
      expect { executor.accumulate_run_usage(run, { "usage" => 5 }) }.not_to raise_error
      expect(runs.get_run(run.id).tokens_in).to eq(0)
    end

    it "adds Anthropic-shaped usage" do
      executor.accumulate_run_usage(run, { "usage" => { "input_tokens" => 30, "output_tokens" => 20 } })
      refreshed = runs.get_run(run.id)
      expect(refreshed.tokens_in).to eq(30)
      expect(refreshed.tokens_out).to eq(20)
    end

    it "adds OpenAI-shaped usage (prompt_tokens / completion_tokens)" do
      executor.accumulate_run_usage(run, { "usage" => { "prompt_tokens" => 5, "completion_tokens" => 7 } })
      refreshed = runs.get_run(run.id)
      expect(refreshed.tokens_in).to eq(5)
      expect(refreshed.tokens_out).to eq(7)
    end

    it "applies price table for matching provider+model" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface llm llm1
         provider anthropic
        exit
        prices anthropic
         model claude-x  in 3.0 out 15.0
        exit
      PRC
      iface = doc.interfaces.first
      executor.accumulate_run_usage(
        run,
        { "model" => "claude-x", "usage" => { "input_tokens" => 1_000_000, "output_tokens" => 1_000_000 } },
        iface, doc
      )
      refreshed = runs.get_run(run.id)
      expect(refreshed.cost_usd).to eq(18.0)
    end
  end

  describe "#price_for_call" do
    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface llm m
         provider anthropic
        exit
        prices anthropic
         model claude-x  in 1.0 out 2.0
        exit
      PRC
    end

    it "returns 0 when iface is nil" do
      expect(executor.send(:price_for_call, nil, "claude-x", doc, 1, 2)).to eq(0.0)
    end

    it "returns 0 when document is nil" do
      expect(executor.send(:price_for_call, doc.interfaces.first, "claude-x", nil, 1, 2)).to eq(0.0)
    end

    it "returns 0 when model is nil" do
      expect(executor.send(:price_for_call, doc.interfaces.first, nil, doc, 1, 2)).to eq(0.0)
    end

    it "returns 0 when provider is missing" do
      iface = doc.interfaces.first
      iface.type_fields = iface.type_fields.dup
      iface.type_fields.delete("provider")
      expect(executor.send(:price_for_call, iface, "claude-x", doc, 1, 2)).to eq(0.0)
    end

    it "returns 0 when no matching price table exists" do
      iface = doc.interfaces.first
      iface.type_fields["provider"] = "openai"
      expect(executor.send(:price_for_call, iface, "claude-x", doc, 1, 2)).to eq(0.0)
    end

    it "returns 0 when model entry is missing in the table" do
      expect(executor.send(:price_for_call, doc.interfaces.first, "other-model", doc, 1, 2)).to eq(0.0)
    end
  end

  describe "#update_context_with_output" do
    it "no-ops when scrubbed output is nil" do
      context = Prouterd::Runtime::Context.new({})
      block = double(name: "b")
      executor.update_context_with_output(block, context, nil)
      expect(context.to_h).to eq({})
    end

    it "sets context[block.name] = output" do
      context = Prouterd::Runtime::Context.new({})
      block = double(name: "b")
      executor.update_context_with_output(block, context, { "ok" => true })
      expect(context.get("b")).to eq("ok" => true)
    end
  end

  describe "#enforce_produces" do
    let(:result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "", artifacts: [],
        output_json: { "x" => 1 }, error_type: nil, error_message: nil,
        duration_ms: 0, started_at: nil, finished_at: nil
      )
    end

    it "returns the result unchanged when produces is empty" do
      block = double(produces: [])
      expect(executor.send(:enforce_produces, block, result)).to eq(result)
    end

    it "returns the result unchanged when every declared artifact is present" do
      art = Prouterd::Runner::ArtifactDescriptor.new(name: "a.csv", host_path: "/x/a.csv", size_bytes: 1, content_type: nil, checksum: "x")
      r = Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "", artifacts: [art],
        output_json: {}, error_type: nil, error_message: nil,
        duration_ms: 0, started_at: nil, finished_at: nil
      )
      block = double(produces: ["a.csv"])
      expect(executor.send(:enforce_produces, block, r)).to eq(r)
    end

    it "rewrites to missing_artifact when a declared artifact is absent" do
      block = double(produces: ["foo.csv"])
      out = executor.send(:enforce_produces, block, result)
      expect(out.error_type).to eq("missing_artifact")
      expect(out.error_message).to include("foo.csv")
    end
  end

  describe "#build_input_payload" do
    it "returns a Hash with run_id / process / block / context" do
      run = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      block = double(name: "b")
      ctx = Prouterd::Runtime::Context.new("event" => { "k" => "v" })
      payload = executor.send(:build_input_payload, run, block, ctx)
      expect(payload["run_id"]).to eq(run.uid)
      expect(payload["process"]).to eq("p")
      expect(payload["block"]).to eq("b")
      expect(payload["context"]).to eq("event" => { "k" => "v" })
    end
  end

  describe "#enforce_output_contract" do
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:step) { runs.create_step(run_id: run.id, block_name: "b") }
    let(:db_mutex) { Mutex.new }
    let(:redactor) { Prouterd::Runtime::Redactor.new([]) }

    def doc_with_contract(violation)
      parse(<<~PRC)
        router demo
        exit
        contract c1
         require value
         on violation #{violation}
        exit
        interface docker img
         image x
        exit
        process p
         block b
          interface docker img
          contract c1
         exit
        exit
      PRC
    end

    let(:passing_result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "", artifacts: [],
        output_json: { "value" => 5 }, error_type: nil, error_message: nil,
        duration_ms: 0, started_at: nil, finished_at: nil
      )
    end

    let(:failing_result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "", artifacts: [],
        output_json: { "wrong" => 5 }, error_type: nil, error_message: nil,
        duration_ms: 0, started_at: nil, finished_at: nil
      )
    end

    it "returns the result unchanged when block has no contract_name" do
      block = double(contract_name: nil)
      r = executor.send(:enforce_output_contract, block, doc_with_contract("warn"), passing_result, run, step, db_mutex, redactor)
      expect(r).to eq(passing_result)
    end

    it "returns the result unchanged when contract has no name (defensive)" do
      block = doc_with_contract("warn").processes.first.blocks.first
      r = executor.send(:enforce_output_contract, block, Prouterd::Config::AST::Document.new, passing_result, run, step, db_mutex, redactor)
      expect(r).to eq(passing_result)
    end

    it "returns the result unchanged when validation passes" do
      doc = doc_with_contract("warn")
      block = doc.processes.first.blocks.first
      r = executor.send(:enforce_output_contract, block, doc, passing_result, run, step, db_mutex, redactor)
      expect(r).to eq(passing_result)
    end

    it "warn mode keeps the result a success and logs to system stream" do
      doc = doc_with_contract("warn")
      block = doc.processes.first.blocks.first
      r = executor.send(:enforce_output_contract, block, doc, failing_result, run, step, db_mutex, redactor)
      expect(r.error_type).to be_nil
      logs = runs.list_logs(run.id)
      expect(logs.find { |l| l.stream == "system" }).not_to be_nil
    end

    it "retry mode rewrites to contract_violation with retryable error_type" do
      doc = doc_with_contract("retry")
      block = doc.processes.first.blocks.first
      r = executor.send(:enforce_output_contract, block, doc, failing_result, run, step, db_mutex, redactor)
      expect(r.error_type).to eq("contract_violation")
      expect(r.output_json).to be_nil
    end

    it "fail mode rewrites to contract_violation" do
      doc = doc_with_contract("fail")
      block = doc.processes.first.blocks.first
      r = executor.send(:enforce_output_contract, block, doc, failing_result, run, step, db_mutex, redactor)
      expect(r.error_type).to eq("contract_violation")
    end
  end

  describe "#execute_barrier_block" do
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:db_mutex) { Mutex.new }
    let(:ctx_mutex) { Mutex.new }

    def barrier_block(name, members, strategy)
      block = Prouterd::Config::AST::Block.new(name: name, line: 1)
      block.barrier_for = members
      block.barrier_join_strategy = strategy
      block
    end

    it "merge-children: shallow-merges Hash member outputs" do
      ctx = Prouterd::Runtime::Context.new(
        "m1" => { "a" => 1 },
        "m2" => { "b" => 2 },
        "m3" => "ignored-non-hash"
      )
      b = barrier_block("bar", ["m1", "m2", "m3"], "merge-children")
      res = executor.send(:execute_barrier_block, run, b, ctx, ctx_mutex, db_mutex)
      expect(res.output_json).to eq("a" => 1, "b" => 2)
    end

    it "any: returns the first member's output as winner" do
      ctx = Prouterd::Runtime::Context.new("m1" => nil, "m2" => { "winner" => "m2" })
      b = barrier_block("bar", ["m1", "m2"], "any")
      res = executor.send(:execute_barrier_block, run, b, ctx, ctx_mutex, db_mutex)
      expect(res.output_json["winner"]).to eq("m2")
      expect(res.output_json["join_strategy"]).to eq("any")
    end

    it "default AND-style: aggregates members + succeeded + failed" do
      ctx = Prouterd::Runtime::Context.new("m1" => { "x" => 1 }, "m2" => nil)
      b = barrier_block("bar", ["m1", "m2"], "all-required")
      res = executor.send(:execute_barrier_block, run, b, ctx, ctx_mutex, db_mutex)
      expect(res.output_json["succeeded"]).to eq(["m1"])
      expect(res.output_json["failed"]).to eq(["m2"])
      expect(res.output_json["members"]).to eq("m1" => { "x" => 1 }, "m2" => nil)
    end
  end

  describe "#build_env: iface secret_ref pointing to an undeclared secret" do
    it "skips silently (next unless secret) instead of raising" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret DECLARED
         source env DECLARED_VAL
        exit
        interface llm m
         provider claude_cli
         secret DECLARED
         secret GHOST
        exit
        process p
         block b
          interface llm m
          prompt "hi"
         exit
        exit
      PRC
      ENV["DECLARED_VAL"] = "tok"
      # Strip the GHOST secret declaration in-place so the iface's
      # `secret GHOST` ref points at nothing. (Validator would reject
      # at apply time, but build_env keeps a defensive `next unless`.)
      doc.secrets.reject! { |s| s.name == "GHOST" }
      run = runs.create_run(process_name: "p", input_event: {})
      process = doc.processes.first
      block = process.blocks.first
      iface = doc.interfaces.find { |i| i.name == "m" }
      env = executor.build_env(run, process, block, iface, doc, 1)
      expect(env["DECLARED"]).to eq("tok")
      expect(env).not_to have_key("GHOST")
    ensure
      ENV.delete("DECLARED_VAL")
    end
  end

  describe "#execute_single_attempt defensive guards" do
    let(:run) { runs.create_run(process_name: "p", input_event: {}) }
    let(:process) { double(name: "p") }
    let(:db_mutex) { Mutex.new }
    let(:ctx_mutex) { Mutex.new }
    let(:context) { Prouterd::Runtime::Context.new({}) }
    let(:redactor) { Prouterd::Runtime::Redactor.new([]) }
    let(:document) { Prouterd::Config::AST::Document.new }

    it "returns invalid_block when the block has no interface_ref" do
      block = Prouterd::Config::AST::Block.new(name: "b", line: 1)
      block.interface_ref = nil
      result = executor.execute_single_attempt(run, process, block, 1, context, document,
                                                db_mutex, ctx_mutex, redactor)
      expect(result.error_type).to eq("invalid_block")
      expect(result.error_message).to include("no `interface` directive")
    end

    it "returns invalid_interface when interface_ref points to an undeclared iface" do
      block = Prouterd::Config::AST::Block.new(name: "b", line: 1)
      block.interface_ref = Prouterd::Config::AST::InterfaceRef.new(type: "docker", name: "ghost", line: 1)
      result = executor.execute_single_attempt(run, process, block, 1, context, document,
                                                db_mutex, ctx_mutex, redactor)
      expect(result.error_type).to eq("invalid_interface")
      expect(result.error_message).to include("docker ghost")
    end
  end

  describe "#build_env: empty secret list paths" do
    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block b
          interface docker img
         exit
        exit
      PRC
    end
    let(:run) { runs.create_run(process_name: "p", input_event: {}) }
    let(:process) { doc.processes.first }
    let(:block) { process.blocks.first }
    let(:iface) { doc.interfaces.first }

    it "returns just the PROUTER_* env when the iface has no secret_ref fields set" do
      env = executor.build_env(run, process, block, iface, doc, 1)
      expect(env.keys).to include("PROUTER_RUN_ID", "PROUTER_BLOCK_NAME")
      expect(env.keys).not_to include(match(/SECRET/))
    end
  end

  describe "max-cost-usd enforcement" do
    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block b
          interface docker img
          max-cost-usd 0.01
         exit
        exit
      PRC
    end

    it "rewrites the result into cost_cap_exceeded when accumulated cost passes the cap" do
      run = runs.create_run(process_name: "p", input_event: {})
      runs.add_run_usage(run.id, cost_usd: 1.5) # bump cost above the cap
      process = doc.processes.first
      block = process.blocks.first

      runner = Class.new do
        def run(_req)
          Prouterd::Runner::ExecutionResult.new(
            exit_code: 0, stdout: "", stderr: "",
            output_json: { "ok" => true }, artifacts: [],
            error_type: nil, error_message: nil,
            duration_ms: 0, started_at: nil, finished_at: nil
          )
        end
      end.new
      ex = described_class.new(
        db: db, runs: runs, runner: runner,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: Prouterd::Events.default,
        logger: Prouterd::NullLogger.new, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      result = ex.execute_single_attempt(run, process, block, 1,
                                          Prouterd::Runtime::Context.new({}),
                                          doc, Mutex.new, Mutex.new,
                                          Prouterd::Runtime::Redactor.new([]))
      expect(result.error_type).to eq("cost_cap_exceeded")
    end
  end

  describe "#build_log_sink" do
    let(:run) { runs.create_run(process_name: "p", input_event: {}) }
    let(:step) { runs.create_step(run_id: run.id, block_name: "b") }
    let(:db_mutex) { Mutex.new }
    let(:redactor) { Prouterd::Runtime::Redactor.new([]) }

    it "returns a proc that no-ops on nil / empty content" do
      sink = executor.send(:build_log_sink, run, step, db_mutex, redactor)
      expect { sink.call(nil) }.not_to raise_error
      expect { sink.call("") }.not_to raise_error
      expect(runs.list_logs(run.id)).to be_empty
    end

    it "persists non-empty content and publishes a :log_appended event" do
      received = []
      events = Prouterd::Events.new
      handle = events.subscribe(:log_appended) { |_t, p| received << p[:content] }
      ex = described_class.new(
        db: db, runs: runs, runner: Prouterd::Runner::StubRunner.new,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: events, logger: Prouterd::NullLogger.new, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      sink = ex.send(:build_log_sink, run, step, db_mutex, redactor)
      sink.call("hello", "stdout")
      events.unsubscribe(handle)
      expect(received).to eq(["hello"])
      expect(runs.list_logs(run.id).map(&:content)).to include("hello")
    end

    it "swallows publish when @events is nil" do
      ex_no_events = described_class.new(
        db: db, runs: runs, runner: Prouterd::Runner::StubRunner.new,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: nil, logger: Prouterd::NullLogger.new, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      sink = ex_no_events.send(:build_log_sink, run, step, db_mutex, redactor)
      expect { sink.call("hi") }.not_to raise_error
      expect(runs.list_logs(run.id).map(&:content)).to include("hi")
    end
  end

  describe "#stage_artifact_inputs" do
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:db_mutex) { Mutex.new }

    it "returns {} when block has no artifact_inputs" do
      block = double(artifact_inputs: [])
      expect(executor.send(:stage_artifact_inputs, run, block, db_mutex)).to eq({})
    end

    it "raises TriggerError when an upstream artifact is missing" do
      ai = double(from_block: "up", from_artifact: "x.csv", local_name: "x.csv")
      block = double(artifact_inputs: [ai], name: "b")
      expect {
        executor.send(:stage_artifact_inputs, run, block, db_mutex)
      }.to raise_error(Prouterd::Runtime::TriggerError, /not found in run/)
    end
  end
end
