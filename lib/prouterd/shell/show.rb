require_relative "../util/duration_parser"

module Prouterd
  module Shell
    # Read-only `show` subsystem. Used by Privileged and Config modes (and
    # any sub-mode that wants to expose `show` from inside a session).
    module Show
      module_function

      def execute(args, session, out, _err)
        head, *rest = args.map(&:value)
        case head
        when "version"           then show_version(out)
        when "status"            then show_status(session, out)
        when "running-config"    then show_running(session, out)
        when "candidate-config"  then show_candidate(session, out)
        when "startup-config"    then show_startup(session, out)
        when "commits"           then list_commits(session, out)
        when "commit"            then show_commit(rest, session, out)
        when "diff"              then show_diff(session, out)
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
        when "run"       then show_run(rest, session, out)
        when "logs"      then show_logs(rest, session, out)
        when "artifacts" then show_artifacts(rest, session, out)
        when "dead-letter" then show_dead_letter(rest, session, out)
        else
          raise CommandError, "unknown show target '#{head}'"
        end
      end

      # ----- generic / status -----

      def show_version(out)
        out.puts "prouter #{Prouterd::VERSION}"
      end

      def show_status(session, out)
        out.puts "hostname:        #{session.hostname}"
        out.puts "router:          #{session.running_config.router&.name || '(none)'}"
        out.puts "config mode:     #{session.in_config_mode? ? 'editing candidate' : 'idle'}"
        out.puts "interfaces:      #{session.running_config.interfaces.length}"
        out.puts "processes:       #{session.running_config.processes.length}"
        out.puts "secrets:         #{session.running_config.secrets.length}"
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
        if rest.length == 2 && rest[0] == "process"
          process_name = rest[1]
        elsif !rest.empty?
          raise CommandError, "syntax: show runs [process <name>]"
        end

        repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
        runs = repo.list_runs(limit: 100, process_name: process_name)
        if runs.empty?
          out.puts process_name ? "No runs for process '#{process_name}'." : "No runs."
          return
        end
        out.puts "%-15s %-25s %-10s %-19s %s" % ["UID", "PROCESS", "STATUS", "STARTED", "DURATION"]
        runs.each do |r|
          dur = r.duration_ms ? "#{r.duration_ms}ms" : "-"
          out.puts "%-15s %-25s %-10s %-19s %s" % [
            r.uid, r.process_name[0, 25], r.status,
            (r.started_at || r.created_at).to_s[0, 19], dur
          ]
        end
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
        out.puts "Status: #{run.status}"
        out.puts "Config commit: #{run.process_config_commit_id || '-'}"
        out.puts "Interface: #{run.interface_name || '-'}"
        out.puts "Started: #{run.started_at || '-'}"
        out.puts "Finished: #{run.finished_at || '-'}"
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
        # syntax: show logs run <uid> [block <name>]
        unless rest.length >= 2 && rest[0] == "run"
          raise CommandError, "syntax: show logs run <uid> [block <name>]"
        end
        unless session.store
          out.puts "(no DB attached — logs not available)"
          return
        end
        run_uid = rest[1]
        block_name = nil
        if rest.length == 4 && rest[2] == "block"
          block_name = rest[3]
        elsif rest.length != 2
          raise CommandError, "syntax: show logs run <uid> [block <name>]"
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
        # syntax: show artifacts run <uid> [block <name>]
        unless rest.length >= 2 && rest[0] == "run"
          raise CommandError, "syntax: show artifacts run <uid> [block <name>]"
        end
        unless session.store
          out.puts "(no DB attached — artifacts not available)"
          return
        end
        run_uid = rest[1]
        block_name = nil
        if rest.length == 4 && rest[2] == "block"
          block_name = rest[3]
        elsif rest.length != 2
          raise CommandError, "syntax: show artifacts run <uid> [block <name>]"
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

        artifacts = repo.list_artifacts(run.id, step_id: step_id)
        if artifacts.empty?
          out.puts "No artifacts."
          return
        end
        out.puts "%-25s %-30s %-10s %-12s" % ["BLOCK", "NAME", "SIZE", "CHECKSUM"]
        artifacts.each do |a|
          out.puts "%-25s %-30s %-10s %-12s" % [a.block_name, a.name, "#{a.size_bytes}B", a.checksum.to_s[0, 12]]
        end
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

      def show_candidate(session, out)
        if session.in_config_mode?
          text = Config::Renderer.render(session.candidate_config)
          out.print(text.empty? ? "(empty candidate)\n" : text)
        else
          out.puts "No candidate configuration. Use 'configure terminal' first."
        end
      end

      def show_diff(session, out)
        if !session.in_config_mode?
          out.puts "No candidate configuration."
          return
        end

        a = Config::Renderer.render(session.running_config).split("\n", -1)
        b = Config::Renderer.render(session.candidate_config).split("\n", -1)
        emit_diff(a, b, out)
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
        out.puts "%-30s %-12s %-8s %-8s" % ["NAME", "QUEUE", "BLOCKS", "ROUTES"]
        processes.each do |p|
          out.puts "%-30s %-12s %-8d %-8d" % [
            p.name, p.queue_name || "-", p.blocks.length, p.routes.length
          ]
        end
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
          tag = if b.docker?
                  "docker image=#{b.image || '-'}"
                elsif b.shell?
                  "shell exec=#{(b.shell_exec || '-')[0, 30]}"
                else
                  "(no type)"
                end
          out.puts "    #{b.name}  #{tag}"
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
                   when "webhook" then "#{i.method || '?'} #{i.path || '?'}"
                   when "cron"    then "schedule=#{i.schedule.inspect}"
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
          out.puts "  path:     #{i.path || '(unset)'}"
          out.puts "  method:   #{i.method || '(unset)'}"
          if i.auth
            out.puts "  auth:     #{i.auth.scheme} secret=#{i.auth.secret_name}"
          end
        when "cron"
          out.puts "  schedule: #{i.schedule || '(unset)'}"
          out.puts "  timezone: #{i.timezone || '(unset)'}"
        end
      end

      def list_policies(session, out)
        ps = session.active_config.policies
        if ps.empty?
          out.puts "No policies defined."
          return
        end
        out.puts "%-25s %-10s %-12s %-12s %-10s" % ["NAME", "ATTEMPTS", "BACKOFF", "INIT", "MAX"]
        ps.each do |p|
          out.puts "%-25s %-10s %-12s %-12s %-10s" % [
            p.name,
            p.retry_attempts || "-",
            p.retry_backoff || "-",
            p.retry_initial_delay_ms ? Util::DurationParser.render(p.retry_initial_delay_ms) : "-",
            p.retry_max_delay_ms ? Util::DurationParser.render(p.retry_max_delay_ms) : "-"
          ]
        end
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
        out.puts "  timeout:       #{p.timeout_ms ? Util::DurationParser.render(p.timeout_ms) : '-'}"
      end

      def list_queues(session, out)
        qs = session.active_config.queues
        if qs.empty?
          out.puts "No queues defined."
          return
        end
        out.puts "%-25s %-12s %-12s" % ["NAME", "CONCURRENCY", "TIMEOUT"]
        qs.each do |q|
          out.puts "%-25s %-12s %-12s" % [
            q.name,
            q.concurrency || "-",
            q.timeout_ms ? Util::DurationParser.render(q.timeout_ms) : "-"
          ]
        end
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
        out.puts "%-30s %-10s %s" % ["NAME", "SOURCE", "REF"]
        ss.each do |s|
          out.puts "%-30s %-10s %s" % [s.name, s.source_type || "-", s.source_value || "-"]
        end
      end

      def show_secret(rest, session, out)
        require_args(rest, 1, "show secret <name>")
        s = session.active_config.secrets.find { |x| x.name == rest.first }
        raise CommandError, "no such secret '#{rest.first}'" unless s

        # Spec §23.1/§23.2: never display secret VALUES.
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
          out.puts "%-25s %-40s %-10s" % ["NAME", "IMAGE", "TIMEOUT"]
          p.blocks.each do |b|
            out.puts "%-25s %-40s %-10s" % [
              b.name,
              (b.image || "-").to_s[0, 40],
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
        out.puts "  type:    #{b.execution_type || '(none)'}"
        if b.docker?
          out.puts "  image:   #{b.image || '-'}"
          out.puts "  command: #{b.command || '-'}"
          out.puts "  network: #{b.network}"
          out.puts "  pull:    #{b.pull}" if b.pull
          out.puts "  user:    #{b.user}" if b.user
          out.puts "  memory:  #{b.memory}" if b.memory
          out.puts "  cpu:     #{b.cpu}"   if b.cpu
        elsif b.shell?
          out.puts "  exec:    #{b.shell_exec || '-'}"
          out.puts "  cwd:     #{b.shell_cwd || '(daemon cwd)'}"
          out.puts "  shell:   #{b.shell_path}" if b.shell_path
          unless b.shell_env.empty?
            out.puts "  env:     #{b.shell_env.map { |k, v| "#{k}=#{v}" }.join(', ')}"
          end
        end
        out.puts "  timeout: #{b.timeout_ms ? Util::DurationParser.render(b.timeout_ms) : '-'}"
        out.puts "  retry:   #{b.retry_policy_name || '-'}"
        out.puts "  contract: #{b.contract_name || '-'}"
        out.puts "  input:   #{b.input || '-'}"
        out.puts "  output:  #{b.output || '-'}"
        out.puts "  state:   #{b.shutdown ? 'disabled' : 'enabled'}"
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
