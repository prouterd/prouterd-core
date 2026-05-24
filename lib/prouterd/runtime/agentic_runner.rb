# frozen_string_literal: true

require "json"
require "time"

module Prouterd
  module Runtime
    # Multi-turn LLM tool-use driver, extracted from Orchestrator.
    #
    # Owns:
    #   * `agentic on` block dispatch — provider validation, prompt /
    #     system / interface-body templating, max-tokens / max-turns
    #     resolution.
    #   * MCP-aware allowed-tools resolution: a `tool <name>` declared
    #     in the document resolves to the AST node; an `<iface>.<name>`
    #     name resolves to a live MCP tool from the pool's tools/list.
    #   * Per-block tool dispatcher: turns each `tool_use` from the LLM
    #     into a synthetic Runner::RunRequest against the tool's
    #     implementation iface, routed through the same CallRunner the
    #     orchestrator uses for ordinary blocks (or, for namespaced
    #     names, through the MCP pool's call_tool).
    #
    # Cross-collaborator helpers live on `host` (currently the
    # Orchestrator). Phase 4 (BlockExecutor extraction) will move these
    # helpers off the Orchestrator and into BlockExecutor; AgenticRunner's
    # `host:` reference becomes BlockExecutor at that point.
    #
    # Host contract:
    #   * host.secret_overlay(document) → Hash<String, String>
    #   * host.templated_fields(fields, scope) → Hash
    #   * host.build_env(run, process, block, iface, document) → Hash<String, String>
    #   * host.accumulate_run_usage(run, scrubbed_output_json, iface, document) → void
    #   * host.update_context_with_output(block, context, scrubbed) → void
    class AgenticRunner
      AGENTIC_PROVIDERS = %w[anthropic codex_cli].freeze

      def initialize(runs:, runner:, mcp_pool:, host:)
        @runs = runs
        @runner = runner
        @mcp_pool = mcp_pool
        @host = host
      end

      def execute(run, process, block, context, document, db_mutex, ctx_mutex, redactor, attempt)
        ref = block.interface_ref
        iface = ref && document.interfaces.find { |i| i.name == ref.name && i.type == ref.type }
        unless iface && ref.type == "llm"
          return invalid_agentic(block, "agentic block must reference `interface llm <name>`")
        end

        provider = (iface.type_fields["provider"] || "").to_s
        if provider == "claude_cli"
          return invalid_agentic(block,
            "agentic mode is not supported with `provider claude_cli` " \
            "(Claude Code CLI's `-p` mode is one-shot; use `provider anthropic` HTTP for multi-turn)")
        end
        unless AGENTIC_PROVIDERS.include?(provider)
          return invalid_agentic(
            block,
            "agentic mode supports providers #{AGENTIC_PROVIDERS.join('/')} (got '#{provider}'); switch the interface or `agentic off`"
          )
        end

        # Resolve allowed-tools to the descriptors the LLM gets in
        # its tool array. Two universes:
        #   - Plain `name` resolves to a `tool <name>` declaration.
        #   - Namespaced `<iface>.<name>` is an MCP server tool. The
        #     descriptor comes from the live tools/list (via the
        #     pool); if the pool isn't wired in (tests / CLI) or the
        #     server is degraded, fail clean.
        # Block.mcp_refs further widens the allowed set: every tool
        # advertised by the listed mcp interfaces becomes available
        # under its namespaced name. If `allowed-tools` is set, that
        # acts as a tighter filter on top.
        allowed = []
        block.allowed_tools.each do |name|
          if name.include?(".")
            ns, tool_name = name.split(".", 2)
            descriptor = mcp_tool_descriptor(ns, tool_name)
            unless descriptor
              return invalid_agentic(block,
                                     "allowed-tools '#{name}' is not advertised by mcp interface '#{ns}' " \
                                     "(check daemon log for `%MCP-3-START_FAILED` / `%MCP-6-READY`)")
            end
            allowed << descriptor
          else
            tool = document.tools.find { |t| t.name == name }
            return invalid_agentic(block, "allowed-tools references unknown tool '#{name}'") unless tool

            allowed << tool
          end
        end

        # If the block names mcp interfaces but no `allowed-tools`,
        # auto-include every tool those interfaces advertise.
        if block.allowed_tools.empty? && !block.mcp_refs.empty?
          block.mcp_refs.each do |ns|
            tools_for_iface(ns).each do |t|
              allowed << build_mcp_tool(ns, t)
            end
          end
        end

        # Resolve templated prompt/system + interface fields. The agentic
        # path doesn't run the per-call args through the same templating
        # the synchronous LlmCaller path does, because the prompt /
        # system are read directly off block.type_fields above. Extend
        # the same hand-templating to the subprocess-only call fields
        # so an operator can write `cwd "{{event.repo_path}}"`.
        overlay = { "iteration" => attempt, "secret" => @host.secret_overlay(document) }
        scope = RetryEngine::OverlayContext.new(context, overlay)
        prompt    = nil
        system_m  = nil
        templated_iface = nil
        templated_call  = {}
        ctx_mutex.synchronize do
          prompt    = Prouterd::Util::Templater.render(block.type_fields["prompt"].to_s, scope)
          system_m  = Prouterd::Util::Templater.render(block.type_fields["system"].to_s, scope)
          templated_iface = @host.templated_fields(iface.type_fields || {}, scope)
          %w[cwd reasoning-effort].each do |k|
            raw = block.type_fields[k]
            templated_call[k] = raw.is_a?(String) ? Prouterd::Util::Templater.render(raw, scope) : raw
          end
        end

        api_key = nil
        auth = templated_iface["auth"]
        if auth && auth.respond_to?(:secret_name)
          api_key = @host.build_env(run, process, block, iface, document)[auth.secret_name]
        end
        base_url = templated_iface["base-url"]
        base_url = nil if base_url.respond_to?(:empty?) && base_url.empty?
        base_url ||= "https://api.anthropic.com"
        model = templated_iface["model"].to_s

        max_tokens = (block.type_fields["max-tokens"] || "1024").to_i
        max_tokens = 1024 if max_tokens < 1
        env = @host.build_env(run, process, block, iface, document)

        dispatcher = build_tool_dispatcher(run, process, block, document, env)

        # Persist a step row before the first turn so logs/usage land
        # against it. The orchestrator's outer attempt machinery would
        # write its own row at execute_single_attempt's return — we
        # short-circuit before that, so write here.
        step = nil
        db_mutex.synchronize do
          step = @runs.create_step(run_id: run.id, block_name: block.name, attempt: attempt, image: nil)
          @runs.update_step(step.id, status: "running", started_at: Time.now.utc.iso8601(3))
        end

        outcome = Iface::LlmAgentic.run(
          provider:         provider,
          model:            model,
          base_url:         base_url,
          api_key:          api_key,
          binary:           templated_iface["binary"],
          home:             templated_iface["home"],
          sandbox:          templated_iface["sandbox"],
          cwd:              templated_call["cwd"],
          reasoning_effort: templated_call["reasoning-effort"],
          prompt:           prompt,
          system_msg:       system_m,
          max_tokens:       max_tokens,
          max_turns:        block.tool_call_limit,
          tools:            allowed,
          dispatcher:       dispatcher,
          timeout_ms:       block.timeout_ms
        )

        scrubbed = outcome[:output_json] ? redactor.redact_json(outcome[:output_json]) : nil
        now = Time.now.utc.iso8601(3)
        db_mutex.synchronize do
          @runs.update_step(
            step.id,
            status: outcome[:ok] ? "success" : "failed",
            finished_at: now,
            duration_ms: 0,
            exit_code: outcome[:exit_code],
            error_type: outcome[:error_type],
            error_message: redactor.redact(outcome[:error_message]),
            output_json: scrubbed ? JSON.dump(scrubbed) : nil
          )
          @host.accumulate_run_usage(run, scrubbed, iface, document)
        end

        if outcome[:ok]
          ctx_mutex.synchronize { @host.update_context_with_output(block, context, scrubbed) }
        end

        Runner::ExecutionResult.new(
          exit_code: outcome[:exit_code],
          stdout: outcome[:stdout].to_s,
          stderr: outcome[:stderr].to_s,
          output_json: scrubbed,
          artifacts: [],
          error_type: outcome[:error_type],
          error_message: outcome[:error_message],
          duration_ms: 0,
          started_at: now, finished_at: now
        )
      end

      private

      def invalid_agentic(block, message)
        Runner::ExecutionResult.new(
          exit_code: nil, stdout: "", stderr: "",
          output_json: nil, artifacts: [],
          error_type: "invalid_agentic", error_message: "block '#{block.name}': #{message}",
          duration_ms: 0, started_at: nil, finished_at: nil
        )
      end

      # MCP tool descriptor as it appears to the agentic loop. The
      # live `tools/list` response from the server is shaped as
      # `{name, description, inputSchema}`; we wrap it so the rest of
      # the loop reads it like a `tool <name>` AST node would.
      def mcp_tool_descriptor(iface_name, tool_name)
        return nil unless @mcp_pool

        tools = tools_for_iface(iface_name)
        descriptor = tools.find { |t| t["name"] == tool_name }
        return nil unless descriptor

        build_mcp_tool(iface_name, descriptor)
      end

      def tools_for_iface(iface_name)
        return [] unless @mcp_pool

        @mcp_pool.tool_snapshot([iface_name])[iface_name] || []
      end

      def build_mcp_tool(iface_name, descriptor)
        Iface::McpToolRef.new(
          iface_name:   iface_name,
          tool_name:    descriptor["name"],
          full_name:    "#{iface_name}.#{descriptor["name"]}",
          description:  descriptor["description"],
          input_schema: descriptor["inputSchema"]
        )
      end

      # Build the per-block tool dispatch callback. Each tool_use from
      # the LLM is mapped to a synthetic RunRequest against the tool's
      # implementation iface, dispatched through the same CallRunner
      # the orchestrator uses for ordinary blocks. Returns a Hash with
      # output_json / error_type / error_message — the agentic driver
      # serialises the appropriate tool_result content.
      def build_tool_dispatcher(run, process, block, document, parent_env)
        mcp_pool = @mcp_pool
        runner = @runner
        lambda do |name:, input:|
          # Namespaced names → MCP pool. `tools/list` already validated
          # the prefix at agentic-block setup; we re-check here for
          # the case where a server hot-restarted and lost the tool.
          if name.include?(".")
            unless mcp_pool
              next ({ error_type: "mcp_unavailable",
                      error_message: "mcp pool is not wired into this orchestrator" })
            end
            timeout_ms = block.timeout_ms || 60_000
            next mcp_pool.call_tool(name, input || {}, timeout_ms: timeout_ms)
          end

          tool = document.tools.find { |t| t.name == name }
          next ({ error_type: "unknown_tool", error_message: "tool '#{name}' is not declared" }) unless tool

          impl = tool.implementation
          iface = document.interfaces.find { |i| i.name == impl.iface_name && i.type == impl.iface_type }
          next ({ error_type: "unknown_iface",
                  error_message: "tool '#{name}' implementation iface '#{impl.iface_type} #{impl.iface_name}' is not declared" }) unless iface

          # Merge interface body + tool args (LLM-supplied). Tool's
          # `call <name>` value goes into type_fields["call"] verbatim
          # so the local_repo plugin (and any other plugin keying on
          # `call`) sees it.
          #
          # input_json carries the raw LLM-supplied args too. HTTP /
          # postgres / llm callers consume args via type_fields (one
          # call_field per kind); shell-backed tools have only one
          # call_field (`exec`), so the LLM args wouldn't otherwise
          # reach the script. ShellRunner writes input_json to
          # /prouter/input.json (env: PROUTER_INPUT_PATH) — the script
          # reads its `op`/`key`/`jql`/etc. from there.
          fields = (iface.type_fields || {}).dup
          fields["call"] = impl.call_name if impl.call_name && !impl.call_name.empty?
          tool_args = (input || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
          tool_args.each { |k, v| fields[k] = AgenticRunner.stringify_arg(v) }

          req = Runner::RunRequest.new(
            run_uid: run.uid, process_name: process.name,
            block_name: "#{block.name}::tool::#{name}",
            execution_type: iface.type, attempt: 1,
            env: parent_env, input_json: tool_args, timeout_ms: 60_000,
            type_fields: fields, staged_inputs: {}
          )
          result = runner.run(req)

          if result.success?
            { output_json: result.output_json || {} }
          else
            {
              error_type:    result.error_type || "tool_failed",
              error_message: result.error_message || "tool '#{name}' returned non-zero exit"
            }
          end
        end
      end

      def self.stringify_arg(value)
        case value
        when String then value
        when nil    then ""
        else             JSON.dump(value)
        end
      end
    end
  end
end
