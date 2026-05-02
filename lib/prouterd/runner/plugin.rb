module Prouterd
  module Runner
    # Subclass `Plugin` to add a new block execution type. One plugin file
    # describes:
    #
    #   1. The DSL `type <name>` keyword that activates it.
    #   2. The fields that appear inside `type <name> ... exit`.
    #   3. Which Runner class executes a block of this type at runtime.
    #
    # The framework drives parser/validator/renderer/show/tracer/CLI off
    # of this declaration — adding a new runner does NOT require touching
    # any core file.
    #
    # Minimal example:
    #
    #     class MyRunnerPlugin < Prouterd::Runner::Plugin
    #       type "my_runner"
    #
    #       field :endpoint, kind: :string, required: true
    #       field :token,    kind: :string
    #       field :verbose,  kind: :enum, enum: %w[on off], default: "off"
    #
    #       runner MyRunner
    #     end
    #
    #     Prouterd::Runner::Registry.register(MyRunnerPlugin)
    #
    # The corresponding DSL inside a `.prc`:
    #
    #     block call_api
    #      type my_runner
    #       endpoint "https://api.example.com"
    #       token "$SECRET"
    #       verbose on
    #      exit
    #     exit
    #
    # See `lib/prouterd/runner/plugins/docker.rb` and `shell.rb` for the
    # built-in plugins as worked examples.
    class Plugin
      # One field declared by `field :name, ...`. Stored in declaration
      # order — that order drives the renderer's emit order so the
      # canonical config is stable.
      Field = Struct.new(
        :name,         # Symbol — both the DSL keyword and the storage key
        :kind,         # :string | :enum | :command | :env_pair
        :required,     # true/false — validator enforces
        :enum,         # Array<String> for kind: :enum
        :default,      # Optional default value (also affects rendering: omit when value == default)
        :description,  # Short human-readable hint for `show` / errors
        keyword_init: true
      ) do
        # The token that appears in the DSL line (e.g. "image", "env").
        def dsl_keyword
          name.to_s
        end

        # Hash key used inside `block.type_fields`.
        def storage_key
          name.to_s
        end
      end

      class << self
        # Required: declare the DSL `type <name>` token.
        def type(name)
          @type_name = name.to_s
        end

        def type_name
          @type_name or raise "Plugin #{self} missing `type \"...\"` declaration"
        end

        # Declare a field. Order matters for rendering.
        #
        #   kind: :string     — single token, accepts word or quoted string
        #   kind: :enum       — single token, must match `enum:` list
        #   kind: :command    — joins all remaining tokens into one string
        #   kind: :env_pair   — `KEY value`, accumulates into Hash<String,String>
        def field(name, kind: :string, required: false, enum: nil, default: nil,
                  description: nil)
          fields << Field.new(
            name: name, kind: kind, required: required, enum: enum,
            default: default, description: description
          )
        end

        def fields
          @fields ||= []
        end

        def field_for(dsl_keyword)
          fields.find { |f| f.dsl_keyword == dsl_keyword.to_s }
        end

        # Required: the Runner class that will execute blocks of this type.
        # Accepts either a Class or a String class name (resolved lazily,
        # so plugins can reference autoloaded runner classes without
        # forcing an early require — e.g. DockerRunner pulls in docker-api
        # which we don't want at parse-time).
        #
        # The framework calls `runner_class.new(in_flight: in_flight)` by
        # default. If your runner needs different init kwargs, override
        # `build_runner` instead.
        def runner(klass_or_name = nil)
          @runner_ref = klass_or_name if klass_or_name
          @runner_ref
        end

        def runner_class
          ref = @runner_ref or raise "Plugin #{self} missing `runner <Class>` declaration"
          ref.is_a?(Class) ? ref : Object.const_get(ref)
        end

        # Override in your subclass if your runner needs custom construction.
        # `opts` is `{ in_flight: <InFlightRegistry|nil> }`.
        def build_runner(opts = {})
          init_kwargs = runner_class.instance_method(:initialize).parameters
                                    .select { |type, _| %i[key keyreq].include?(type) }
                                    .map { |_, name| name }
          filtered = opts.slice(*init_kwargs)
          runner_class.new(**filtered)
        end

        # Default fallback values for missing fields. Used by the orchestrator
        # when populating `type_fields` for a block that didn't set a default-
        # valued field.
        def defaults
          fields.each_with_object({}) do |f, h|
            h[f.storage_key] = f.default unless f.default.nil?
          end
        end
      end
    end
  end
end
