module Prouterd
  module Shell
    # router-style tab completion for the interactive shell.
    #
    # Reline gives us the partial token + the full line buffer. We split the
    # line into "already-typed" tokens, ask the current mode (and the active
    # session) for candidate completions, and filter by the partial prefix.
    #
    # router-OS behavior:
    #   * `sh` + Tab → "show " (unique prefix expansion)
    #   * `show ` + Tab Tab → list of all show targets
    #   * `show ru` + Tab → "show running-config "
    #   * `show run ` + Tab → list of run uids when there are runs
    #
    # We implement the basics: per-mode command completion, context-aware
    # completion for `show`, `no`, `replay`, `cancel`, `process`, `block`,
    # `route`, `interface`, `secret`, `policy`, `queue`, `trace`.
    class Completer
      def initialize(session)
        @session = session
      end

      # Reline.completion_proc entry point.
      def call(partial, line_buffer)
        candidates = candidates_for(partial, line_buffer)
        # Filter by what the user has actually typed so far in this token.
        matches = candidates.select { |c| c.start_with?(partial) }
        matches.uniq.sort
      end

      private

      def candidates_for(partial, line_buffer)
        return [] if @session.mode_stack.empty?

        mode = @session.mode_stack.last
        tokens = tokenize_so_far(line_buffer, partial)

        # First word: complete from the mode's command list.
        return mode_command_keys(mode) if tokens.empty?

        # Subsequent words: dispatch by the head and current mode.
        head = tokens.first
        contextual_completions(mode, head, tokens, partial)
      end

      # Tokenize the line UP TO the partial. The partial is what Reline is
      # actively completing — so the prior tokens are everything before
      # that has been typed and separated by whitespace.
      def tokenize_so_far(line_buffer, partial)
        text = line_buffer.to_s
        # Strip the partial off the right side.
        text = text[0...(text.length - partial.length)]
        text.split(/\s+/).reject(&:empty?)
      end

      def mode_command_keys(mode)
        mode.commands.keys
      end

      def contextual_completions(mode, head, tokens, _partial)
        case head
        when "show"      then show_completions(tokens)
        when "no"        then no_completions(mode, tokens)
        when "process"   then process_name_completions(tokens)
        when "block"     then block_name_completions(mode, tokens)
        when "route"     then route_completions(mode, tokens)
        when "interface" then interface_completions(tokens)
        when "secret"    then secret_completions(mode, tokens)
        when "policy"    then policy_name_completions(tokens)
        when "queue"     then queue_name_completions(tokens)
        when "type"      then type_completions(tokens)
        when "trace"     then trace_completions(tokens)
        when "trigger"   then trigger_completions(tokens)
        when "replay"    then replay_completions(tokens)
        when "cancel"    then cancel_completions(tokens)
        when "rollback"  then rollback_completions(tokens)
        when "configure" then configure_completions(tokens)
        when "write"     then write_completions(tokens)
        when "load", "apply", "diff", "check"
          file_path_completions
        when "match"     then match_completions(tokens)
        when "auth"      then auth_completions(tokens)
        when "retry"     then retry_completions(tokens)
        when "pull"      then %w[never if-missing always]
        when "network"   then %w[on off]
        when "on-failure" then %w[stop continue]
        when "image", "command", "exec", "cwd", "shell", "user", "memory", "cpu"
          [] # free-form; we don't try to enumerate filesystem
        else
          []
        end
      end

      # ---- show <target> ----

      SHOW_TOP_LEVEL = %w[
        version status clock logging history
        running-config startup-config candidate-config commits
        commit diff processes process interfaces interface policies policy
        queues queue secrets secret blocks block routes runs run logs
        artifacts dead-letter
      ].freeze

      def show_completions(tokens)
        # tokens[0] is "show". tokens[1] is the target (or being typed).
        case tokens.length
        when 1 then SHOW_TOP_LEVEL
        when 2
          case tokens[1]
          when "process", "blocks" then process_names
          when "interface" then interface_names
          when "policy"    then policy_names
          when "queue"     then queue_names
          when "secret"    then secret_names
          when "block"     then ["process"]
          when "run"       then recent_run_uids
          when "logs", "artifacts" then ["run"]
          when "commit"    then commit_ids
          when "routes"    then ["process"]
          when "dead-letter" then ["run"]
          else []
          end
        when 3
          case tokens[1]
          when "blocks" then ["process"] if tokens[2] != "process"
          when "block"  then process_names # show block process <here>
          when "logs", "artifacts", "dead-letter" then recent_run_uids
          when "routes" then process_names
          else []
          end || []
        when 4
          case tokens[1]
          when "block" then blocks_in_process(tokens[3])
          when "logs", "artifacts" then ["block"]
          else []
          end
        when 5
          case tokens[1]
          when "logs", "artifacts" then blocks_in_process_of_run(tokens[2])
          else []
          end
        else []
        end
      end

      # ---- no <kind> [name] ----

      def no_completions(mode, tokens)
        # In `(config)#`, `no` removes top-level entities. In sub-modes,
        # `no shutdown` / `no <field>` apply. We just offer a sensible
        # vocabulary; the parser enforces what's actually valid.
        case tokens.length
        when 1
          case mode_kind(mode)
          when :config_process then %w[shutdown block route description queue]
          when :config_block   then %w[shutdown secret command retry timeout input output]
          when :config_route   then %w[shutdown match on-failure]
          when :config         then %w[router secret policy queue interface process route]
          else %w[shutdown]
          end
        when 2
          case tokens[1]
          when "process"   then process_names
          when "interface" then interface_names
          when "policy"    then policy_names
          when "queue"     then queue_names
          when "secret"    then secret_names
          when "block"     then blocks_in_current_mode(mode)
          else []
          end
        else []
        end
      end

      def replay_completions(tokens)
        case tokens.length
        when 1 then ["run"]
        when 2 then recent_run_uids
        when 3 then ["from"]
        when 4 then blocks_for_replay(tokens[2])
        else []
        end
      end

      def cancel_completions(tokens)
        case tokens.length
        when 1 then ["run"]
        when 2 then recent_run_uids
        else []
        end
      end

      def rollback_completions(tokens)
        case tokens.length
        when 1 then ["commit"]
        when 2 then commit_ids
        else []
        end
      end

      def configure_completions(tokens)
        case tokens.length
        when 1 then ["terminal"]
        else []
        end
      end

      def write_completions(tokens)
        case tokens.length
        when 1 then ["memory"]
        else []
        end
      end

      def trigger_completions(tokens)
        case tokens.length
        when 1 then ["process"]
        when 2 then process_names
        when 3 then ["input"]
        else []
        end
      end

      def trace_completions(tokens)
        case tokens.length
        when 1 then ["event"]
        when 3 then ["interface"]
        when 4 then interface_names
        else []
        end
      end

      def process_name_completions(tokens)
        return process_names if tokens.length == 1

        []
      end

      def block_name_completions(mode, tokens)
        # Inside config-process, `block <name>` either creates new (no completion)
        # or edits existing. Offer existing names so users can `block <Tab>`.
        if tokens.length == 1 && mode_kind(mode) == :config_process
          process = mode.respond_to?(:process) ? mode.process : nil
          return process ? process.blocks.map(&:name) : []
        end
        []
      end

      def route_completions(mode, tokens)
        case mode_kind(mode)
        when :config
          # global route: route interface <iface> process <proc>
          case tokens.length
          when 1 then ["interface"]
          when 2 then interface_names
          when 3 then ["process"]
          when 4 then process_names
          else []
          end
        when :config_process
          process = mode.respond_to?(:process) ? mode.process : nil
          return [] unless process

          case tokens.length
          when 1, 2 then process.blocks.map(&:name)
          else []
          end
        else []
        end
      end

      def interface_completions(tokens)
        case tokens.length
        when 1 then %w[webhook manual cron]
        else []
        end
      end

      def secret_completions(mode, tokens)
        # In config mode top-level: `secret <NAME>`. Inside config-block:
        # `secret <NAME>` references a top-level secret.
        if tokens.length == 1 && mode_kind(mode) == :config_block
          secret_names
        else
          []
        end
      end

      def policy_name_completions(tokens)
        return policy_names if tokens.length == 1

        []
      end

      def queue_name_completions(tokens)
        return queue_names if tokens.length == 1

        []
      end

      def type_completions(tokens)
        case tokens.length
        when 1 then %w[docker shell]
        else []
        end
      end

      def auth_completions(tokens)
        case tokens.length
        when 1 then %w[bearer]
        when 2 then ["secret"]
        when 3 then secret_names
        else []
        end
      end

      def retry_completions(tokens)
        case tokens.length
        when 1 then policy_names + %w[policy attempts backoff initial-delay max-delay]
        when 2
          # `retry policy <name>` long form
          tokens[1] == "policy" ? policy_names : []
        else []
        end
      end

      def match_completions(_tokens)
        # Operators when typing the third token.
        Prouterd::Config::AST::Match::OPERATORS
      end

      def file_path_completions
        # Best-effort filesystem completion. Reline already does some of
        # this when no completion_proc is set; with one set, we delegate
        # to Dir glob on the partial path.
        # Returning [] keeps Reline's default fallback off, which is fine —
        # most users will type paths fully or paste them.
        []
      end

      # ---- session lookups ----

      def process_names
        active_doc.processes.map(&:name)
      end

      def interface_names
        active_doc.interfaces.map(&:name)
      end

      def policy_names
        active_doc.policies.map(&:name)
      end

      def queue_names
        active_doc.queues.map(&:name)
      end

      def secret_names
        active_doc.secrets.map(&:name)
      end

      def blocks_in_process(name)
        process = active_doc.processes.find { |p| p.name == name }
        process ? process.blocks.map(&:name) : []
      end

      def blocks_in_current_mode(mode)
        return blocks_in_process(mode.process.name) if mode.respond_to?(:process)

        []
      end

      def blocks_in_process_of_run(run_uid)
        return [] unless @session.store

        repo = Prouterd::Storage::Repositories::Runs.new(@session.store.db)
        run = repo.get_run_by_uid(run_uid)
        return [] unless run

        repo.list_steps(run.id).map(&:block_name).uniq
      end

      def blocks_for_replay(run_uid)
        blocks_in_process_of_run(run_uid)
      end

      def recent_run_uids
        return [] unless @session.store

        repo = Prouterd::Storage::Repositories::Runs.new(@session.store.db)
        repo.list_runs(limit: 30).map(&:uid)
      rescue StandardError
        []
      end

      def commit_ids
        return [] unless @session.store

        @session.store.list_commits(limit: 50).map { |c| c.id.to_s }
      rescue StandardError
        []
      end

      def active_doc
        @session.active_config
      end

      # Map a Mode instance to a stable symbol so we can dispatch in case
      # statements without coupling to class names everywhere.
      def mode_kind(mode)
        case mode
        when Prouterd::Shell::Modes::User           then :user
        when Prouterd::Shell::Modes::Privileged     then :privileged
        when Prouterd::Shell::Modes::Config         then :config
        when Prouterd::Shell::Modes::ConfigProcess  then :config_process
        when Prouterd::Shell::Modes::ConfigBlock    then :config_block
        when Prouterd::Shell::Modes::ConfigProcessRoute, Prouterd::Shell::Modes::ConfigGlobalRoute
          :config_route
        when Prouterd::Shell::Modes::Section        then :config_section
        else :unknown
        end
      end
    end
  end
end
