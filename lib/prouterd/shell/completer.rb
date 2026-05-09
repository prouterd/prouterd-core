module Prouterd
  module Shell
    # router-style tab completion for the read-only operator shell.
    # The interactive `configure terminal` flow was removed, so the
    # completer only needs to cover privileged-mode commands and
    # their args (`show <target>`, `replay run <uid>`, `cancel run <uid>`,
    # `rollback commit <id>`, `apply <file>`, etc).
    #
    # Reline gives us the partial token + the full line buffer. We
    # tokenize, dispatch by the head, and filter by what the user has
    # typed so far in this token.
    class Completer
      def initialize(session)
        @session = session
      end

      def call(partial, line_buffer)
        candidates = candidates_for(partial, line_buffer)
        candidates.select { |c| c.start_with?(partial) }.uniq.sort
      end

      private

      def candidates_for(partial, line_buffer)
        return [] if @session.mode_stack.empty?

        mode = @session.mode_stack.last
        tokens = tokenize_so_far(line_buffer, partial)

        return mode.commands.keys if tokens.empty?

        head = tokens.first
        contextual_completions(head, tokens)
      end

      def tokenize_so_far(line_buffer, partial)
        text = line_buffer.to_s
        text = text[0...(text.length - partial.length)]
        text.split(/\s+/).reject(&:empty?)
      end

      def contextual_completions(head, tokens)
        case head
        when "show"     then show_completions(tokens)
        when "trigger"  then trigger_completions(tokens)
        when "replay"   then replay_completions(tokens)
        when "cancel"   then cancel_completions(tokens)
        when "rollback" then rollback_completions(tokens)
        when "write"    then write_completions(tokens)
        when "copy"     then copy_completions(tokens)
        when "load", "apply", "diff", "check"
          (tokens.length == 1) ? prc_files : []
        else []
        end
      end

      # ---- show <target> [args...] ----

      SHOW_TOP_LEVEL = %w[
        version status clock logging history
        running-config startup-config
        commits commit diff
        processes process interfaces interface policies policy
        queues queue secrets secret blocks block routes runs run logs
        artifacts dead-letter mcp local-repo
      ].freeze

      def show_completions(tokens)
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
          when "block"  then process_names
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

      # ---- run-lifecycle / commit ops ----

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

      def write_completions(tokens)
        case tokens.length
        when 1 then ["memory"]
        else []
        end
      end

      def copy_completions(tokens)
        case tokens.length
        when 1 then ["running-config"]
        when 2 then ["startup-config"]
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

      # ---- name lookups against the running config ----

      def active_doc; @session.active_config; end

      def process_names;   active_doc.processes.map(&:name); end
      def interface_names; active_doc.interfaces.map(&:name); end
      def policy_names;    active_doc.policies.map(&:name); end
      def queue_names;     active_doc.queues.map(&:name); end
      def secret_names;    active_doc.secrets.map(&:name); end

      def blocks_in_process(name)
        proc = active_doc.processes.find { |p| p.name == name }
        proc ? proc.blocks.map(&:name) : []
      end

      def recent_run_uids
        return [] unless @session.store

        Storage::Repositories::Runs.new(@session.store.db).list_runs(limit: 20).map(&:uid)
      rescue StandardError
        []
      end

      def blocks_for_replay(run_uid)
        return [] unless @session.store && run_uid

        repo = Storage::Repositories::Runs.new(@session.store.db)
        run = repo.get_run_by_uid(run_uid)
        return [] unless run

        repo.list_steps(run.id).map(&:block_name).uniq
      rescue StandardError
        []
      end

      def blocks_in_process_of_run(run_uid)
        return [] unless @session.store && run_uid

        repo = Storage::Repositories::Runs.new(@session.store.db)
        run = repo.get_run_by_uid(run_uid)
        return [] unless run

        repo.list_steps(run.id).map(&:block_name).uniq
      rescue StandardError
        []
      end

      def commit_ids
        return [] unless @session.store

        @session.store.list_commits(limit: 50).map { |c| c.id.to_s }
      rescue StandardError
        []
      end

      def prc_files
        Dir.glob("*.prc") + Dir.glob("examples/*.prc")
      rescue StandardError
        []
      end
    end
  end
end
