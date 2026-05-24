# frozen_string_literal: true

require_relative "../util/duration_parser"

module Prouterd
  module Shell
    # Read-only `show` subsystem. Used by Privileged and Config modes (and
    # any sub-mode that wants to expose `show` from inside a session).
    module Show
      module_function

      # Canonical show-target keys. router-style unique-prefix expansion is
      # applied before dispatch, so `sh ru` -> `running-config`, `sh int` ->
      # `interfaces`, `sh pol` -> `policies`, etc. An ambiguous abbreviation
      # raises CommandError listing the candidates.
      TARGETS = %w[
        version status clock logging history
        running-config startup-config
        commits commit
        processes process interfaces interface
        policies policy queues queue secrets secret
        blocks block routes
        runs run logs artifacts dead-letter
        mcp local-repo
      ].freeze

      def execute(args, session, out, _err)
        head, *rest = args.map(&:value)
        head = expand_target(head, has_args: !rest.empty?)

        case head
        when "version"           then show_version(out)
        when "status"            then show_status(session, out)
        when "clock"             then show_clock(out)
        when "logging"           then show_logging(rest, out)
        when "history"           then show_history(out)
        when "running-config"    then show_running(session, out)
        when "startup-config"    then show_startup(session, out)
        when "commits"           then list_commits(session, out)
        when "commit"            then show_commit(rest, session, out)
        when "processes"         then list_processes(session, out)
        when "process"           then show_process(rest, session, out)
        when "interfaces"        then list_interfaces(session, out)
        when "interface"         then show_interface(rest, session, out)
        when "policies"          then list_policies(session, out)
        when "policy"            then show_policy(rest, session, out)
        when "queues"            then list_queues(session, out)
        when "queue"             then show_queue(rest, session, out)
        when "secrets"           then list_secrets(session, out)
        when "secret"            then show_secret(rest, session, out)
        when "blocks"            then list_blocks(rest, session, out)
        when "block"             then show_block(rest, session, out)
        when "routes"            then list_routes(rest, session, out)
        when "runs"      then list_runs(rest, session, out)
        when "run"
          # router-CLI habit: bare `show run` (no UID) means `show running-config`.
          # `show run <uid>` keeps its prouter-native meaning of "show one run".
          rest.empty? ? show_running(session, out) : show_run(rest, session, out)
        when "logs"      then show_logs(rest, session, out)
        when "artifacts" then show_artifacts(rest, session, out)
        when "dead-letter" then show_dead_letter(rest, session, out)
        when "mcp"       then show_mcp(session, out)
        when "local-repo" then show_local_repo(session, out)
        else
          raise CommandError, "unknown show target '#{head}'"
        end
      end

      def expand_target(head, has_args: false)
        return head if head.nil? || TARGETS.include?(head)

        matches = TARGETS.select { |t| t.length > head.length && t.start_with?(head) }
        case matches.length
        when 0 then head
        when 1 then matches.first
        when 2
          # Common singular/plural pair (interface/interfaces, policy/policies,
          # queue/queues, log/logs/logging, ...). router-CLI habit: bare form lists
          # everything; same word with an argument shows one record.
          sg, pl = matches.sort_by(&:length)
          if pl.start_with?(sg) && pl.length - sg.length <= 3
            has_args ? sg : pl
          else
            raise CommandError, "ambiguous show target '#{head}': #{matches.sort.join(', ')}"
          end
        else
          raise CommandError, "ambiguous show target '#{head}': #{matches.sort.join(', ')}"
        end
      end

      # ----- generic / status -----

      def show_version(out)
        out.puts "prouter #{Prouterd::VERSION}"
      end

      def show_status(session, out)
        out.puts "hostname:        #{session.hostname}"
        out.puts "router:          #{session.running_config.router&.name || '(none)'}"
        out.puts "interfaces:      #{session.running_config.interfaces.length}"
        out.puts "processes:       #{session.running_config.processes.length}"
        out.puts "secrets:         #{session.running_config.secrets.length}"
      end

      # ----- router-iconic show targets -----

      def show_clock(out)
        out.puts Time.now.utc.strftime("%H:%M:%S.%3N UTC %a %b %e %Y")
      end

      # `show logging` with no args prints the configuration summary.
      # With any of `last <N>`, `severity <0-7>`, `facility <NAME>` it
      # tails the in-memory ring buffer (Prouterd::Logger.ring) — same
      # buffer the daemon writes to as it emits the structured log lines. The
      # ring is process-local and lossy; for durable audit, capture
      # stdout via journald/docker logs.
      def show_logging(rest, out)
        if rest.empty?
          level = ENV["PROUTERD_LOG_LEVEL"] || "info"
          capture_cap = ENV["PROUTERD_LOG_CAPTURE_BYTES"] || "1048576"
          ring = Prouterd::Logger.ring
          out.puts "Logging configuration:"
          out.puts "  level:        #{level} (override via PROUTERD_LOG_LEVEL)"
          out.puts "  format:       <ts>: %FACILITY-SEV-MNEMONIC: msg k=v ..."
          out.puts "  destination:  stdout (capture via journald / docker logs / k8s sidecar)"
          out.puts "  capture cap:  #{capture_cap} bytes per container stream (override via PROUTERD_LOG_CAPTURE_BYTES)"
          out.puts "  ring buffer:  #{ring.tail.length} entries cached for 'show logging last <N>'"
          return
        end

        n = nil
        severity = nil
        facility = nil
        i = 0
        while i < rest.length
          case rest[i]
          when "last"
            raise CommandError, "syntax: show logging [last <N>] [severity <0-7>] [facility <NAME>]" unless rest[i + 1]
            n = Integer(rest[i + 1]) rescue (raise CommandError, "last: '#{rest[i + 1]}' is not an integer")
            i += 2
          when "severity"
            raise CommandError, "syntax: show logging [last <N>] [severity <0-7>] [facility <NAME>]" unless rest[i + 1]
            severity = Integer(rest[i + 1]) rescue (raise CommandError, "severity: '#{rest[i + 1]}' is not an integer 0-7")
            unless (0..7).cover?(severity)
              raise CommandError, "severity must be 0-7 (0=emergency, 7=debug)"
            end
            i += 2
          when "facility"
            raise CommandError, "syntax: show logging [last <N>] [severity <0-7>] [facility <NAME>]" unless rest[i + 1]
            facility = rest[i + 1].to_s.upcase
            i += 2
          else
            raise CommandError, "syntax: show logging [last <N>] [severity <0-7>] [facility <NAME>]"
          end
        end

        n ||= 50
        rows = Prouterd::Logger.ring.tail(n, severity: severity, facility: facility)
        if rows.empty?
          out.puts "(no log entries match — ring is empty or filters too tight)"
          return
        end
        rows.each { |entry| out.puts entry[:line] }
      end

      def show_history(out)
        if defined?(Reline::HISTORY) && !Reline::HISTORY.empty?
          width = Reline::HISTORY.length.to_s.length
          Reline::HISTORY.to_a.each_with_index do |line, i|
            out.puts "  %*d  %s" % [width, i + 1, line]
          end
        else
          out.puts "(no history available — Reline not loaded or session has no commands)"
        end
      end

      # ----- config dumps -----

      def show_running(session, out)
        text = Config::Renderer.render(session.running_config)
        out.print(text.empty? ? "(empty configuration)\n" : text)
      end

      def show_startup(session, out)
        unless session.store
          out.puts "(no DB attached — startup-config not available)"
          return
        end
        commit = session.store.startup_commit
        if commit
          out.puts "! startup-config is commit #{commit.id} (#{commit.short_checksum}) saved at #{commit.created_at}"
          out.puts
          out.print(commit.rendered_config)
        else
          out.puts "(startup-config not set; use 'write memory' to bless current running)"
        end
      end

      def list_commits(session, out)
        unless session.store
          out.puts "(no DB attached — commits not available)"
          return
        end
        commits = session.store.list_commits(limit: 100)
        if commits.empty?
          out.puts "No commits."
          return
        end
        running_id = session.store.running_commit&.id
        startup_id = session.store.startup_commit&.id
        out.puts "%-6s %-14s %-19s %-12s %s" % ["ID", "CHECKSUM", "CREATED", "AUTHOR", "MESSAGE"]
        commits.each do |c|
          markers = []
          markers << "running" if c.id == running_id
          markers << "startup" if c.id == startup_id
          marker_str = markers.empty? ? "" : " (#{markers.join(', ')})"
          out.puts "%-6s %-14s %-19s %-12s %s%s" % [
            c.id,
            c.short_checksum,
            c.created_at.to_s[0, 19],
            (c.author || "-").to_s[0, 12],
            (c.message || "").to_s[0, 60],
            marker_str
          ]
        end
      end

      # ----- local-repo -----
      #
      # Lists declared `interface local_repo` entries with the most
      # recent auto-pull outcome per whitelisted repo. Entries that
      # haven't been polled yet (daemon just booted, or `auto-pull`
      # not declared) show "(no pull recorded)".
      def show_local_repo(session, out)
        ifaces = session.active_config.interfaces.select { |i| i.type == "local_repo" }
        if ifaces.empty?
          out.puts "No `interface local_repo` declarations in the running config."
          return
        end
        statuses = Prouterd::Iface::LocalRepoStatus.snapshot
        by_iface = statuses.group_by(&:iface_name)
        ifaces.each do |iface|
          out.puts "interface local_repo #{iface.name}"
          out.puts "  auto-pull: #{iface.type_fields['auto-pull'] || '(none — pulls disabled)'}"
          rows = by_iface[iface.name] || []
          if rows.empty?
            out.puts "  pulls:     (no pull recorded yet)"
          else
            out.puts "  pulls:"
            rows.each do |r|
              status_word = r.ok ? "ok" : "FAIL"
              tail = r.ok ? r.summary.to_s : r.error.to_s
              out.puts "    %-30s %-4s  %-19s  %s" % [
                r.repo, status_word, r.checked_at.to_s[0, 19], tail[0, 70]
              ]
            end
          end
        end
      end

      # ----- mcp -----
      #
      # Lists declared `interface mcp` entries from the running config
      # and warns when the chosen `server <kind>` runner can't be
      # found on the local PATH. Live daemon health (state / tools)
      # comes from /v1/mcp — the shell process doesn't talk to the
      # daemon's Pool directly.
      def show_mcp(session, out)
        ifaces = session.active_config.interfaces.select { |i| i.type == "mcp" }
        if ifaces.empty?
          out.puts "No `interface mcp` declarations in the running config."
          return
        end
        out.puts "%-25s %-6s %-40s %s" % ["NAME", "KIND", "SPEC", "PATH/STATUS"]
        ifaces.each do |i|
          server = i.type_fields["server"] || {}
          warn = Prouterd::Iface::Mcp::ServerCommand.warn_if_unresolvable(server)
          status = warn ? "! #{warn}" : "ok"
          out.puts "%-25s %-6s %-40s %s" % [
            i.name, server["kind"] || "-",
            (server["spec"] || "")[0, 40], status
          ]
        end
        out.puts
        out.puts "Live state from a running daemon: GET /v1/mcp."
      end

      # ----- dead-letter -----

      def show_dead_letter(rest, session, out)
        unless session.store
          out.puts "(no DB attached — dead-letter not available)"
          return
        end
        repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)

        if rest.empty?
          failed = repo.list_runs(limit: 100, status: "failed")
          if failed.empty?
            out.puts "No failed runs."
            return
          end
          out.puts "%-15s %-25s %-19s %s" % ["UID", "PROCESS", "FINISHED", "ERROR"]
          failed.each do |r|
            err = (r.error_summary || "").to_s[0, 60]
            out.puts "%-15s %-25s %-19s %s" % [
              r.uid,
              r.process_name[0, 25],
              (r.finished_at || r.started_at || r.created_at).to_s[0, 19],
              err
            ]
          end
        elsif rest.length == 2 && rest[0] == "run"
          run = repo.get_run_by_uid(rest[1])
          raise CommandError, "no such run '#{rest[1]}'" unless run
          unless run.status == "failed"
            out.puts "Run '#{run.uid}' is in status '#{run.status}', not 'failed'."
            return
          end
          show_run([rest[1]], session, out) # delegate to detail renderer
        else
          raise CommandError, "syntax: show dead-letter [run <uid>]"
        end
      end

      # ----- runs / logs / artifacts -----

      def list_runs(rest, session, out)
        unless session.store
          out.puts "(no DB attached — runs not available)"
          return
        end

        process_name = nil
        thread_id = nil
        i = 0
        while i < rest.length
          case rest[i]
          when "process"
            raise CommandError, "syntax: show runs [process <name>] [thread <id>]" unless rest[i + 1]
            process_name = rest[i + 1]
            i += 2
          when "thread"
            raise CommandError, "syntax: show runs [process <name>] [thread <id>]" unless rest[i + 1]
            thread_id = rest[i + 1]
            i += 2
          else
            raise CommandError, "syntax: show runs [process <name>] [thread <id>]"
          end
        end

        repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
        runs = repo.list_runs(limit: 100, process_name: process_name, thread_id: thread_id)
        if runs.empty?
          out.puts case
                   when process_name && thread_id then "No runs for process '#{process_name}' thread '#{thread_id}'."
                   when process_name              then "No runs for process '#{process_name}'."
                   when thread_id                 then "No runs for thread '#{thread_id}'."
                   else "No runs."
                   end
          return
        end
        Table.render(out,
          { "UID" => 15, "PROCESS" => 20, "THREAD" => 15, "STATUS" => 10, "STARTED" => 19, "DURATION" => nil },
          runs.map do |r|
            [r.uid, r.process_name[0, 20], (r.thread_id || "-")[0, 15], r.status,
             (r.started_at || r.created_at).to_s[0, 19],
             r.duration_ms ? "#{r.duration_ms}ms" : "-"]
          end)
      end

      def show_run(rest, session, out)
        require_args(rest, 1, "show run <uid>")
        unless session.store
          out.puts "(no DB attached — run details not available)"
          return
        end
        repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
        run = repo.get_run_by_uid(rest.first)
        raise CommandError, "no such run '#{rest.first}'" unless run

        out.puts "Run: #{run.uid}"
        out.puts "Process: #{run.process_name}"
        out.puts "Thread: #{run.thread_id}" if run.thread_id
        out.puts "Status: #{run.status}"
        out.puts "Config commit: #{run.process_config_commit_id || '-'}"
        out.puts "Interface: #{run.interface_name || '-'}"
        out.puts "Started: #{run.started_at || '-'}"
        out.puts "Finished: #{run.finished_at || '-'}"
        if run.tokens_in.to_i.positive? || run.tokens_out.to_i.positive?
          out.puts "Tokens: in=#{run.tokens_in.to_i} out=#{run.tokens_out.to_i}"
        end
        out.puts "Error: #{run.error_summary}" if run.error_summary
        out.puts
        out.puts "Steps:"
        steps = repo.list_steps(run.id)
        if steps.empty?
          out.puts "  (none)"
        else
          steps.each do |s|
            duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
            out.puts "  %-25s %-9s %-7s %-10s" % [s.block_name, s.status, duration, "attempt #{s.attempt}"]
            out.puts "    error: [#{s.error_type}] #{s.error_message}" if s.error_type
          end
        end

        artifacts = repo.list_artifacts(run.id)
        unless artifacts.empty?
          out.puts
          out.puts "Artifacts:"
          artifacts.each do |a|
            out.puts "  #{a.block_name}/#{a.name} (#{a.size_bytes} bytes)"
          end
        end
      end

      def show_logs(rest, session, out)
        resolved = resolve_run_and_step(rest, session, out, "logs")
        return unless resolved

        run, step_id, repo = resolved
        logs = repo.list_logs(run.id, step_id: step_id)
        if logs.empty?
          out.puts "No logs."
          return
        end
        steps_by_id = repo.list_steps(run.id).each_with_object({}) { |s, h| h[s.id] = s.block_name }
        logs.each do |entry|
          tag = entry.step_id ? "#{steps_by_id[entry.step_id]}/#{entry.stream}" : "run/#{entry.stream}"
          entry.content.each_line do |line|
            out.puts "[#{tag}] #{line.chomp}"
          end
        end
      end

      def show_artifacts(rest, session, out)
        resolved = resolve_run_and_step(rest, session, out, "artifacts")
        return unless resolved

        run, step_id, repo = resolved
        artifacts = repo.list_artifacts(run.id, step_id: step_id)
        if artifacts.empty?
          out.puts "No artifacts."
          return
        end
        Table.render(out,
          { "BLOCK" => 25, "NAME" => 30, "SIZE" => 10, "CHECKSUM" => nil },
          artifacts.map { |a| [a.block_name, a.name, "#{a.size_bytes}B", a.checksum.to_s[0, 12]] })
      end

      # `show logs run <uid> [block <name>]` and `show artifacts run
      # <uid> [block <name>]` parse the same argument shape, do the
      # same store / run / optional-block resolution. Returns
      # `[run, step_id, repo]` on success, or nil when the request is
      # malformed / store-less (the helper itself emits the message).
      # Caller patterns `or return` on nil to short-circuit cleanly.
      def resolve_run_and_step(rest, session, out, label)
        usage = "syntax: show #{label} run <uid> [block <name>]"
        raise CommandError, usage unless rest.length >= 2 && rest[0] == "run"

        unless session.store
          out.puts "(no DB attached — #{label} not available)"
          return nil
        end

        run_uid = rest[1]
        block_name =
          if rest.length == 4 && rest[2] == "block"
            rest[3]
          elsif rest.length == 2
            nil
          else
            raise CommandError, usage
          end

        repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
        run = repo.get_run_by_uid(run_uid)
        raise CommandError, "no such run '#{run_uid}'" unless run

        step_id = nil
        if block_name
          step = repo.list_steps(run.id).find { |s| s.block_name == block_name }
          raise CommandError, "no such block '#{block_name}' in run '#{run_uid}'" unless step
          step_id = step.id
        end

        [run, step_id, repo]
      end

      def show_commit(rest, session, out)
        require_args(rest, 1, "show commit <id>")
        unless session.store
          out.puts "(no DB attached — commits not available)"
          return
        end
        id = Integer(rest.first) rescue (raise CommandError, "commit id must be an integer")
        commit = session.store.get_commit(id)
        raise CommandError, "no such commit #{id}" unless commit

        out.puts "! commit #{commit.id} (#{commit.short_checksum})"
        out.puts "! created: #{commit.created_at}"
        out.puts "! author:  #{commit.author || '-'}"
        out.puts "! message: #{commit.message || '-'}"
        out.puts
        out.print(commit.rendered_config)
      end

      def diff_file_against_running(rest, session, out)
        require_args(rest, 1, "diff <file>")
        path = rest.first
        source = File.read(path)
        document = Config::Parser.parse(Config::Lexer.tokenize(source))
        b = Config::Renderer.render(document).split("\n", -1)
        a = Config::Renderer.render(session.running_config).split("\n", -1)
        emit_diff(a, b, out)
      rescue Errno::ENOENT
        raise CommandError, "no such file: #{rest.first}"
      rescue Config::ConfigError => e
        raise CommandError, "diff: #{e.message}"
      end

      def emit_diff(a, b, out)
        diff = simple_diff(a, b)
        if diff.empty?
          out.puts "No changes."
        else
          diff.each { |line| out.puts(line) }
        end
      end

      # ----- list / detail commands -----

      def list_processes(session, out)
        processes = session.active_config.processes
        if processes.empty?
          out.puts "No processes defined."
          return
        end
        Table.render(out,
          { "NAME" => 30, "QUEUE" => 12, "BLOCKS" => 8, "ROUTES" => nil },
          processes.map { |p| [p.name, p.queue_name || "-", p.blocks.length, p.routes.length] })
      end

      def show_process(rest, session, out)
        require_args(rest, 1, "show process <name>")
        name = rest.first
        p = session.active_config.processes.find { |x| x.name == name }
        raise CommandError, "no such process '#{name}'" unless p

        out.puts "process #{p.name}"
        out.puts "  description: #{p.description.inspect}" if p.description
        out.puts "  queue:       #{p.queue_name || '-'}"
        out.puts "  shutdown:    #{p.shutdown}"
        out.puts "  blocks (#{p.blocks.length}):"
        p.blocks.each do |b|
          out.puts "    #{b.name}  #{block_summary_tag(b)}"
        end
        out.puts "  routes (#{p.routes.length}):"
        p.routes.each do |r|
          conds = r.matches.empty? ? "" : "  [#{r.matches.length} match]"
          out.puts "    #{r.from_block} -> #{r.to_block}#{conds}"
        end
      end

      def list_interfaces(session, out)
        ifaces = session.active_config.interfaces
        if ifaces.empty?
          out.puts "No interfaces defined."
          return
        end
        out.puts "%-30s %-10s %-8s %s" % ["NAME", "TYPE", "STATE", "DETAIL"]
        ifaces.each do |i|
          state = i.shutdown ? "down" : "up"
          detail = case i.type
                   when "webhook" then "#{i.type_fields['method'] || '?'} #{i.type_fields['path'] || '?'}"
                   when "cron"    then "schedule=#{i.type_fields['schedule'].inspect}"
                   else                "-"
                   end
          out.puts "%-30s %-10s %-8s %s" % [i.name, i.type, state, detail]
        end
      end

      def show_interface(rest, session, out)
        require_args(rest, 1, "show interface <name>")
        name = rest.first
        i = session.active_config.interfaces.find { |x| x.name == name }
        raise CommandError, "no such interface '#{name}'" unless i

        out.puts "interface #{i.type} #{i.name}"
        out.puts "  state:    #{i.shutdown ? 'shutdown' : 'no shutdown'}"
        case i.type
        when "webhook"
          out.puts "  path:     #{i.type_fields['path'] || '(unset)'}"
          out.puts "  method:   #{i.type_fields['method'] || '(unset)'}"
          if (auth = i.type_fields['auth'])
            out.puts "  auth:     #{auth.scheme} secret=#{auth.secret_name}"
          end
        when "cron"
          out.puts "  schedule: #{i.type_fields['schedule'] || '(unset)'}"
          out.puts "  timezone: #{i.type_fields['timezone'] || '(unset)'}"
        end
      end

      def list_policies(session, out)
        ps = session.active_config.policies
        if ps.empty?
          out.puts "No policies defined."
          return
        end
        Table.render(out,
          { "NAME" => 25, "ATTEMPTS" => 10, "BACKOFF" => 12, "INIT" => 12, "MAX" => nil },
          ps.map do |p|
            [p.name,
             p.retry_attempts || "-",
             p.retry_backoff || "-",
             p.retry_initial_delay_ms ? Util::DurationParser.render(p.retry_initial_delay_ms) : "-",
             p.retry_max_delay_ms ? Util::DurationParser.render(p.retry_max_delay_ms) : "-"]
          end)
      end

      def show_policy(rest, session, out)
        require_args(rest, 1, "show policy <name>")
        p = session.active_config.policies.find { |x| x.name == rest.first }
        raise CommandError, "no such policy '#{rest.first}'" unless p

        out.puts "policy #{p.name}"
        out.puts "  attempts:      #{p.retry_attempts || '-'}"
        out.puts "  backoff:       #{p.retry_backoff || '-'}"
        out.puts "  initial-delay: #{p.retry_initial_delay_ms ? Util::DurationParser.render(p.retry_initial_delay_ms) : '-'}"
        out.puts "  max-delay:     #{p.retry_max_delay_ms ? Util::DurationParser.render(p.retry_max_delay_ms) : '-'}"
        unless p.retry_when_matches.empty?
          out.puts "  retry-when:"
          p.retry_when_matches.each do |m|
            values = m.values.empty? ? "" : " #{m.values.join(',')}"
            out.puts "    #{m.path} #{m.operator}#{values}"
          end
        end
        out.puts "  timeout:       #{p.timeout_ms ? Util::DurationParser.render(p.timeout_ms) : '-'}"
      end

      def list_queues(session, out)
        qs = session.active_config.queues
        if qs.empty?
          out.puts "No queues defined."
          return
        end
        Table.render(out,
          { "NAME" => 25, "CONCURRENCY" => 12, "TIMEOUT" => nil },
          qs.map do |q|
            [q.name,
             q.concurrency || "-",
             q.timeout_ms ? Util::DurationParser.render(q.timeout_ms) : "-"]
          end)
      end

      def show_queue(rest, session, out)
        require_args(rest, 1, "show queue <name>")
        q = session.active_config.queues.find { |x| x.name == rest.first }
        raise CommandError, "no such queue '#{rest.first}'" unless q

        out.puts "queue #{q.name}"
        out.puts "  concurrency: #{q.concurrency || '-'}"
        out.puts "  timeout:     #{q.timeout_ms ? Util::DurationParser.render(q.timeout_ms) : '-'}"
      end

      def list_secrets(session, out)
        ss = session.active_config.secrets
        if ss.empty?
          out.puts "No secrets defined."
          return
        end
        Table.render(out,
          { "NAME" => 30, "SOURCE" => 10, "REF" => nil },
          ss.map { |s| [s.name, s.source_type || "-", s.source_value || "-"] })
      end

      def show_secret(rest, session, out)
        require_args(rest, 1, "show secret <name>")
        s = session.active_config.secrets.find { |x| x.name == rest.first }
        raise CommandError, "no such secret '#{rest.first}'" unless s

        # Never display secret VALUES.
        out.puts "secret #{s.name}"
        out.puts "  source: #{s.source_type} #{s.source_value}"
      end

      def list_blocks(rest, session, out)
        # syntax: show blocks process <name>
        if rest.length == 2 && rest[0] == "process"
          process_name = rest[1]
          p = session.active_config.processes.find { |x| x.name == process_name }
          raise CommandError, "no such process '#{process_name}'" unless p
          if p.blocks.empty?
            out.puts "No blocks in process '#{process_name}'."
            return
          end
          out.puts "%-25s %-40s %-10s" % ["NAME", "SUMMARY", "TIMEOUT"]
          p.blocks.each do |b|
            out.puts "%-25s %-40s %-10s" % [
              b.name,
              block_summary_tag(b)[0, 40],
              b.timeout_ms ? Util::DurationParser.render(b.timeout_ms) : "-"
            ]
          end
        else
          raise CommandError, "syntax: show blocks process <name>"
        end
      end

      def show_block(rest, session, out)
        # syntax: show block process <pname> <bname>
        unless rest.length == 3 && rest[0] == "process"
          raise CommandError, "syntax: show block process <process> <block>"
        end
        pname, bname = rest[1], rest[2]
        p = session.active_config.processes.find { |x| x.name == pname }
        raise CommandError, "no such process '#{pname}'" unless p
        b = p.blocks.find { |x| x.name == bname }
        raise CommandError, "no such block '#{pname}/#{bname}'" unless b

        out.puts "block #{pname}/#{b.name}"
        ref = b.interface_ref
        out.puts "  interface: #{ref ? "#{ref.type} #{ref.name}" : '(none)'}"
        plugin = ref && Prouterd::Iface::Registry.lookup(ref.type)
        if plugin
          plugin.call_fields.each do |field|
            value = b.type_fields[field.storage_key]
            label = "#{field.dsl_keyword}:".ljust(10)
            case field.kind
            when :env_pair
              next if value.nil? || value.empty?

              out.puts "  #{label} #{value.map { |k, v| "#{k}=#{v}" }.join(', ')}"
            else
              next if value.nil? && !field.required

              out.puts "  #{label} #{value || '-'}"
            end
          end
        end
        out.puts "  timeout:  #{b.timeout_ms ? Util::DurationParser.render(b.timeout_ms) : '-'}"
        out.puts "  retry:    #{b.retry_policy_name || '-'}"
        out.puts "  contract: #{b.contract_name || '-'}"
        out.puts "  state:    #{b.shutdown ? 'disabled' : 'enabled'}"
        unless b.secret_names.empty?
          out.puts "  secrets: #{b.secret_names.join(', ')}"
        end
      end

      def list_routes(rest, session, out)
        if rest.empty?
          # all routes: global + per-process
          show_global_routes(session, out)
          out.puts ""
          session.active_config.processes.each do |p|
            show_process_routes_table(p, out, prefix: "#{p.name}/")
          end
        elsif rest.length == 2 && rest[0] == "process"
          p = session.active_config.processes.find { |x| x.name == rest[1] }
          raise CommandError, "no such process '#{rest[1]}'" unless p
          show_process_routes_table(p, out)
        else
          raise CommandError, "syntax: show routes [process <name>]"
        end
      end

      def show_global_routes(session, out)
        rs = session.active_config.global_routes
        out.puts "Global routes (interface -> process):"
        if rs.empty?
          out.puts "  (none)"
        else
          rs.each do |r|
            cond = r.matches.empty? ? "" : "  [#{r.matches.length} match]"
            out.puts "  #{r.interface_name} -> #{r.process_name}#{cond}"
          end
        end
      end

      def show_process_routes_table(process, out, prefix: "")
        out.puts "Routes in process '#{process.name}':"
        if process.routes.empty?
          out.puts "  (none)"
          return
        end
        process.routes.each do |r|
          cond = r.matches.empty? ? "" : "  [#{r.matches.length} match]"
          out.puts "  #{prefix}#{r.from_block} -> #{r.to_block}#{cond}"
        end
      end

      # ----- helpers -----

      def require_args(rest, count, syntax)
        return if rest.length == count

        raise CommandError, "syntax: #{syntax}"
      end

      # One-line summary of a block for table/list views. Shows the
      # interface it references plus the most informative call-field
      # (the first :string or :command call_field — typically path / exec /
      # command). Callers truncate as needed for column-aligned tables.
      def block_summary_tag(block)
        ref = block.interface_ref
        return "(no interface)" unless ref

        plugin = Prouterd::Iface::Registry.lookup(ref.type)
        return "#{ref.type} #{ref.name}" unless plugin

        headline_field = plugin.call_fields.find { |f| %i[string command].include?(f.kind) }
        return "#{ref.type} #{ref.name}" unless headline_field

        value = block.type_fields[headline_field.storage_key].to_s
        value = "-" if value.empty?
        "#{ref.type} #{ref.name} #{headline_field.dsl_keyword}=#{value}"
      end

      # Minimal line-by-line diff using LCS over arrays of lines.
      # Sufficient for `show diff` between candidate and running.
      def simple_diff(a, b)
        return [] if a == b

        # Compute LCS via classic DP.
        m = a.length
        n = b.length
        dp = Array.new(m + 1) { Array.new(n + 1, 0) }
        (1..m).each do |i|
          (1..n).each do |j|
            dp[i][j] = if a[i - 1] == b[j - 1]
                        dp[i - 1][j - 1] + 1
                      else
                        [dp[i - 1][j], dp[i][j - 1]].max
                      end
          end
        end

        result = []
        i = m
        j = n
        while i.positive? && j.positive?
          if a[i - 1] == b[j - 1]
            result.unshift("  #{a[i - 1]}")
            i -= 1
            j -= 1
          elsif dp[i - 1][j] >= dp[i][j - 1]
            result.unshift("- #{a[i - 1]}")
            i -= 1
          else
            result.unshift("+ #{b[j - 1]}")
            j -= 1
          end
        end
        while i.positive?
          result.unshift("- #{a[i - 1]}")
          i -= 1
        end
        while j.positive?
          result.unshift("+ #{b[j - 1]}")
          j -= 1
        end
        result.reject { |line| line.start_with?("  ") } # show only +/- lines for compactness
      end
    end
  end
end
