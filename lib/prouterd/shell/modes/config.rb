require_relative "../mode"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # `process-router(config)#`  — top-level config mode.
      #
      # Entered via `configure terminal` from privileged. The Session has a
      # candidate config; all sub-section commands here open editors that
      # mutate the candidate.
      #
      # `commit` signals the shell to validate + swap candidate -> running.
      # `abort` signals the shell to discard candidate.
      # `exit` is treated as abort with uncommitted-change protection.
      class Config < Mode
        PROMPT_SUFFIX = "(config)#".freeze

        IDENT_RE = Prouterd::Config::Parser::IDENT_RE
        ENV_NAME_RE = Prouterd::Config::Parser::ENV_NAME_RE
        INTERFACE_TYPES = Prouterd::Config::AST::Interface::TYPES

        def prompt_suffix
          PROMPT_SUFFIX
        end

        def commands
          {
            "router"    => :cmd_router,
            "secret"    => :cmd_secret,
            "policy"    => :cmd_policy,
            "queue"     => :cmd_queue,
            "interface" => :cmd_interface,
            "process"   => :cmd_process,
            "route"     => :cmd_route,
            "no"        => :cmd_no,
            "show"      => :cmd_show,
            "commit"    => :cmd_commit,
            "abort"     => :cmd_abort,
            "exit"      => :cmd_exit,
            "help"      => :cmd_help,
            "?"         => :cmd_help
          }
        end

        # ----- entry into sub-section editors -----

        def cmd_router(tokens, session, _out, _err)
          expect_arg_count(tokens, 2, "router <name>")
          name = check_identifier(tokens[1].value, "router name")
          doc = session.candidate_config

          if doc.router && doc.router.name != name
            raise CommandError, "router '#{doc.router.name}' already defined; use 'no router' to remove"
          end
          doc.router ||= Prouterd::Config::AST::Router.new(name: name, line: 0)
          enter(Section.for_router(doc.router))
        end

        def cmd_secret(tokens, session, _out, _err)
          expect_arg_count(tokens, 2, "secret <NAME>")
          name = check_env_name(tokens[1].value, "secret name")
          existing = session.candidate_config.secrets.find { |s| s.name == name }
          if existing
            enter(Section.for_secret(existing))
          else
            secret = Prouterd::Config::AST::Secret.new(name: name, line: 0)
            session.candidate_config.secrets << secret
            enter(Section.for_secret(secret))
          end
        end

        def cmd_policy(tokens, session, _out, _err)
          expect_arg_count(tokens, 2, "policy <name>")
          name = check_identifier(tokens[1].value, "policy name")
          existing = session.candidate_config.policies.find { |p| p.name == name }
          if existing
            enter(Section.for_policy(existing))
          else
            policy = Prouterd::Config::AST::Policy.new(name: name, line: 0)
            session.candidate_config.policies << policy
            enter(Section.for_policy(policy))
          end
        end

        def cmd_queue(tokens, session, _out, _err)
          expect_arg_count(tokens, 2, "queue <name>")
          name = check_identifier(tokens[1].value, "queue name")
          existing = session.candidate_config.queues.find { |q| q.name == name }
          if existing
            enter(Section.for_queue(existing))
          else
            queue = Prouterd::Config::AST::Queue.new(name: name, line: 0)
            session.candidate_config.queues << queue
            enter(Section.for_queue(queue))
          end
        end

        def cmd_interface(tokens, session, _out, _err)
          expect_arg_count(tokens, 3, "interface <type> <name>")
          type = tokens[1].value
          name = tokens[2].value
          unless INTERFACE_TYPES.include?(type)
            raise CommandError, "invalid interface type '#{type}' (allowed: #{INTERFACE_TYPES.join(', ')})"
          end
          check_identifier(name, "interface name")
          existing = session.candidate_config.interfaces.find { |i| i.name == name }
          if existing
            if existing.type != type
              raise CommandError, "interface '#{name}' is type '#{existing.type}', not '#{type}'; remove it first"
            end
            enter(Section.for_interface(existing))
          else
            iface = Prouterd::Config::AST::Interface.new(type: type, name: name, line: 0)
            session.candidate_config.interfaces << iface
            enter(Section.for_interface(iface))
          end
        end

        def cmd_process(tokens, session, _out, _err)
          expect_arg_count(tokens, 2, "process <name>")
          name = check_identifier(tokens[1].value, "process name")
          existing = session.candidate_config.processes.find { |p| p.name == name }
          if existing
            enter(ConfigProcess.new(existing))
          else
            process = Prouterd::Config::AST::Process.new(name: name, line: 0)
            session.candidate_config.processes << process
            enter(ConfigProcess.new(process))
          end
        end

        def cmd_route(tokens, session, _out, _err)
          expect_arg_count(tokens, 5, "route interface <iface_name> process <process_name>")
          unless tokens[1].value == "interface" && tokens[3].value == "process"
            raise CommandError, "syntax: route interface <iface_name> process <process_name>"
          end
          iface_name = check_identifier(tokens[2].value, "interface name")
          proc_name = check_identifier(tokens[4].value, "process name")
          doc = session.candidate_config
          existing = doc.global_routes.find do |r|
            r.interface_name == iface_name && r.process_name == proc_name
          end
          if existing
            enter(ConfigGlobalRoute.new(existing))
          else
            route = Prouterd::Config::AST::GlobalRoute.new(
              interface_name: iface_name, process_name: proc_name, line: 0
            )
            doc.global_routes << route
            enter(ConfigGlobalRoute.new(route))
          end
        end

        # ----- deletions -----

        def cmd_no(tokens, session, out, _err)
          expect_min_args(tokens, 2, "no <kind> ...")
          doc = session.candidate_config
          kind = tokens[1].value

          case kind
          when "router"
            expect_arg_count(tokens, 2, "no router")
            doc.router = nil
            out.puts "removed router"
          when "secret"
            expect_arg_count(tokens, 3, "no secret <NAME>")
            removed = doc.secrets.reject! { |s| s.name == tokens[2].value }
            raise CommandError, "no such secret '#{tokens[2].value}'" unless removed
          when "policy"
            expect_arg_count(tokens, 3, "no policy <name>")
            removed = doc.policies.reject! { |p| p.name == tokens[2].value }
            raise CommandError, "no such policy '#{tokens[2].value}'" unless removed
          when "queue"
            expect_arg_count(tokens, 3, "no queue <name>")
            removed = doc.queues.reject! { |q| q.name == tokens[2].value }
            raise CommandError, "no such queue '#{tokens[2].value}'" unless removed
          when "interface"
            expect_arg_count(tokens, 3, "no interface <name>")
            removed = doc.interfaces.reject! { |i| i.name == tokens[2].value }
            raise CommandError, "no such interface '#{tokens[2].value}'" unless removed
          when "process"
            expect_arg_count(tokens, 3, "no process <name>")
            removed = doc.processes.reject! { |p| p.name == tokens[2].value }
            raise CommandError, "no such process '#{tokens[2].value}'" unless removed
          when "route"
            expect_arg_count(tokens, 6, "no route interface <iface> process <proc>")
            unless tokens[2].value == "interface" && tokens[4].value == "process"
              raise CommandError, "syntax: no route interface <iface> process <proc>"
            end
            iface_name = tokens[3].value
            proc_name = tokens[5].value
            removed = doc.global_routes.reject! do |r|
              r.interface_name == iface_name && r.process_name == proc_name
            end
            raise CommandError, "no such global route '#{iface_name} -> #{proc_name}'" unless removed
          else
            raise CommandError, "cannot 'no #{kind}' here"
          end
          :handled
        end

        # ----- show / commit / abort -----

        def cmd_show(tokens, session, out, err)
          if tokens.length == 1
            raise CommandError, "syntax: show <target> [args]"
          end
          Show.execute(tokens[1..], session, out, err)
          :handled
        end

        def cmd_commit(tokens, _session, _out, _err)
          expect_arg_count(tokens, 1, "commit")
          :commit
        end

        def cmd_abort(tokens, _session, _out, _err)
          expect_arg_count(tokens, 1, "abort")
          :abort
        end

        def cmd_exit(_tokens, _session, _out, _err)
          # In Phase 2 we treat top-level exit as an explicit-confirmation
          # request to keep users from losing work silently.
          raise CommandError, "uncommitted candidate changes; use 'commit' or 'abort'"
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            Config mode commands:
              router <name>                 Edit the router section
              secret <NAME>                 Add or edit a secret
              policy <name>                 Add or edit a retry policy
              queue <name>                  Add or edit a queue
              interface <type> <name>       Add or edit a webhook/manual/cron interface
              process <name>                Add or edit a process (enters config-process)
              route interface I process P   Add or edit a global route
              no <kind> [name]              Remove a section (no router|secret|policy|queue|interface|process|route ...)
              show <target>                 Read-only inspection
              commit                        Validate and apply candidate as running
              abort                         Discard candidate, return to privileged
              help, ?                       Show this help
          HELP
          :handled
        end

        # ----- validation helpers -----

        def check_identifier(value, label)
          unless value.match?(IDENT_RE)
            raise CommandError, "invalid #{label} '#{value}' (must match #{IDENT_RE.source})"
          end
          value
        end

        def check_env_name(value, label)
          unless value.match?(ENV_NAME_RE)
            raise CommandError, "invalid #{label} '#{value}' (must be uppercase A-Z, 0-9, _)"
          end
          value
        end
      end
    end
  end
end
