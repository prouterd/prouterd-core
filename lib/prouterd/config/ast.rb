# frozen_string_literal: true

module Prouterd
  module Config
    module AST
      # Root of the parsed config. Top-level sections live here in declaration order.
      # `prices <provider>` — top-level USD pricing table for an LLM
      # provider. Each entry is per-million-token rate for input /
      # output. The runtime cost accumulator multiplies the per-attempt
      # usage envelope against the matching entry to bump
      # `runs.cost_usd`.
      class Prices
        attr_accessor :provider, :line
        attr_reader :entries

        Entry = Struct.new(:model, :price_in, :price_out, :line, keyword_init: true)

        def initialize(provider:, line:)
          @provider = provider
          @line = line
          @entries = []
        end
      end

      # `tool <name>` — top-level declaration of a callable an agentic
      # LLM block can request. The runtime translates the tool to the
      # underlying provider's native tool-use API and dispatches each
      # call to the named outbound interface + call.
      class Tool
        attr_accessor :name, :description, :line, :implementation
        attr_reader :args

        Implementation = Struct.new(:iface_type, :iface_name, :call_name, keyword_init: true)

        def initialize(name:, line:)
          @name = name
          @line = line
          @description = nil
          @args = []
          @implementation = nil
        end
      end

      class Document
        attr_accessor :router
        attr_reader :secrets, :policies, :queues, :interfaces, :processes, :global_routes, :contracts, :tools, :prices

        def initialize
          @router = nil
          @secrets = []
          @policies = []
          @queues = []
          @interfaces = []
          @processes = []
          @global_routes = []
          @contracts = []
          @tools = []
          @prices = []
        end
      end

      class Router
        attr_accessor :name, :version, :hostname, :line

        def initialize(name:, line:)
          @name = name
          @line = line
          @version = nil
          @hostname = nil
        end
      end

      class Secret
        attr_accessor :name, :source_type, :source_value, :line

        def initialize(name:, line:)
          @name = name
          @line = line
          @source_type = nil
          @source_value = nil
        end
      end

      class Policy
        attr_accessor :name, :retry_attempts, :retry_backoff, :retry_initial_delay_ms,
                      :retry_max_delay_ms, :timeout_ms, :line
        attr_reader :retry_when_matches, :retry_feedbacks, :retry_stop_matches

        BACKOFF_TYPES = %w[fixed linear exponential].freeze

        # `retry feedback` — copies a path out of the failed/rejected
        # attempt's output_json into the next attempt's `previous.<into>`
        # overlay. Lets the block template `{{previous.feedback}}` and
        # have it carry verifier-supplied notes from the prior turn.
        Feedback = Struct.new(:from, :into, :line, keyword_init: true)

        def initialize(name:, line:)
          @name = name
          @line = line
          @retry_attempts = nil
          @retry_backoff = nil
          @retry_initial_delay_ms = nil
          @retry_max_delay_ms = nil
          @timeout_ms = nil
          # Optional `retry when <path> <op> <value>` conditions. Multiple
          # entries OR together — any one matching forces a retry. With no
          # entries, retry fires on any failure (legacy behaviour). Path
          # `output.<...>` predicates evaluate against the result's
          # output_json, so reflection loops can fire on success too.
          @retry_when_matches = []
          @retry_feedbacks = []
          # `retry stop-on <path> <op> <value>` — kill switches checked
          # AFTER each attempt against the current run state. Path
          # `run.cost_usd` is the canonical guard; matches force the
          # block to terminate as failed regardless of attempts left.
          @retry_stop_matches = []
        end
      end

      class Queue
        attr_accessor :name, :concurrency, :timeout_ms, :line

        def initialize(name:, line:)
          @name = name
          @line = line
          @concurrency = nil
          @timeout_ms = nil
        end
      end

      class Interface
        attr_accessor :type, :name, :shutdown, :line
        # Plugin-defined body fields, keyed by the plugin's field storage_key.
        # Mirrors `Block#type_fields`. Read directly:
        #   iface.type_fields["path"]
        #   iface.type_fields["auth"]&.secret_name
        attr_accessor :type_fields

        def initialize(type:, name:, line:)
          @type = type
          @name = name
          @line = line
          @shutdown = false
          @type_fields = {}
        end

        def webhook?; type == "webhook"; end
        def manual?;  type == "manual";  end
        def cron?;    type == "cron";    end
      end

      class Auth
        attr_accessor :scheme, :secret_name, :line

        SCHEMES = %w[bearer].freeze

        def initialize(scheme:, secret_name:, line:)
          @scheme = scheme
          @secret_name = secret_name
          @line = line
        end
      end

      # `hmac-sha256 secret <NAME> header <header-name>` on an inbound
      # interface — verify that requests carry a HMAC-SHA256 hex digest
      # of the raw body in the named header, signed with the resolved
      # secret. Body-only signing; provider-specific schemes that wrap
      # the body with a timestamp / version prefix (Slack `v0:...`,
      # Stripe) need a follow-up `payload_template` field — until then,
      # operator handles the prefix at the proxy or accepts replay risk
      # on a private deployment.
      class HmacSignature
        attr_accessor :algorithm, :secret_name, :header, :line

        ALGORITHMS = %w[sha256].freeze

        def initialize(algorithm:, secret_name:, header:, line:)
          @algorithm = algorithm
          @secret_name = secret_name
          @header = header
          @line = line
        end
      end

      class Process
        attr_accessor :name, :description, :queue_name, :shutdown, :timeout_ms,
                      :thread_id_template, :line
        attr_reader :blocks, :routes, :parallel_groups

        def initialize(name:, line:)
          @name = name
          @line = line
          @description = nil
          @queue_name = nil
          @shutdown = false
          @timeout_ms = nil
          @thread_id_template = nil
          @blocks = []
          @routes = []
          # Source-form record of `parallel <name>` sections — kept for
          # rendering. The actual scheduling expansion (member blocks +
          # synthesized barrier block + synthesized routes) lives in
          # @blocks / @routes alongside ordinary content.
          @parallel_groups = []
        end

        def block(name)
          blocks.find { |b| b.name == name }
        end
      end

      # Source-form record of a `parallel <name>` section. Kept so the
      # renderer can reproduce the original DSL. The scheduling effect
      # is realised by the parser expanding the section into member
      # blocks + a synthesized barrier block on @blocks, plus synthetic
      # routes from each member to the barrier on @routes.
      class ParallelGroup
        # all-required       fail the barrier if any member fails
        # all-best-effort    barrier always succeeds; failed members
        #                    show up in `failed:[...]` of output_json
        # merge-children     all-best-effort + flatten: barrier
        #                    output is the shallow-merge of every
        #                    member's output_json (member-name keys
        #                    NOT preserved). For contracts that want
        #                    a single flat shape across N children.
        JOIN_STRATEGIES = %w[all-required all-best-effort merge-children].freeze

        attr_accessor :name, :join_strategy, :line
        attr_reader :member_block_names

        def initialize(name:, line:)
          @name = name
          @line = line
          @join_strategy = "all-required"
          @member_block_names = []
        end
      end

      # Reference from a block to its interface. Same shape as the interface
      # declaration header: `interface <type> <name>`. Stored on Block so the
      # validator can check the type matches the declaration and the runtime
      # can resolve the AST::Interface for dispatch.
      InterfaceRef = Struct.new(:type, :name, :line, keyword_init: true)

      class Block
        # Block declares one outbound interface (HTTP endpoint, LLM, Docker
        # image, shell environment, ...) and supplies per-call args validated
        # against that interface plugin's call_fields. Output is auto-stored
        # at context[block.name]; templating reads from the full context.
        attr_accessor :name, :line, :shutdown,
                      :timeout_ms, :retry_policy_name, :contract_name,
                      :interface_ref, :skip_when, :pause_reason,
                      :fan_out_from, :fan_out_into,
                      :fan_out_maps, :fan_out_dedupe, :fan_out_rate_limit,
                      :barrier_for, :barrier_join_strategy,
                      :max_cost_usd
        attr_reader :secret_names, :produces, :artifact_inputs, :vars

        # Per-call args keyed by the interface plugin's call_field
        # storage_key. Templated at run time against the current context.
        attr_accessor :type_fields

        def initialize(name:, line:)
          @name = name
          @line = line
          @shutdown = false
          @timeout_ms = nil
          @retry_policy_name = nil
          @contract_name = nil
          @secret_names = []
          @interface_ref = nil
          @type_fields = {}
          @produces = []
          @artifact_inputs = []
          @skip_when = nil
          # Local-name overlay for templating. Each value is a template that
          # resolves against the regular context; the resolved string is
          # exposed at top level under the var's name when the block's
          # call-fields are templated.
          @vars = {}
          # When set, the block has no interface dispatch — execution
          # halts here, the run goes to status="paused", and `prouter
          # resume <run> [--value <json>]` injects the supplied JSON as
          # the block's output and continues downstream.
          @pause_reason = nil
          # When both set, after this block succeeds the orchestrator
          # walks `output_json[fan_out_from]` (must be Array) and
          # enqueues one new run of process `fan_out_into` per element
          # — the element is the child run's input_event. Children carry
          # this run's id as parent_run_id so the lineage is queryable.
          @fan_out_from = nil
          @fan_out_into = nil
          # Fan-out enrichment clauses (Phase 38b). Default: empty maps,
          # no dedupe, no rate-limit — minimum primitive shape from
          # Phase 37i still works.
          @fan_out_maps        = []   # Array<{name, from, filter_prefix?, strip_prefix?}>
          @fan_out_dedupe      = nil  # {by, window_ms, when_status?}
          @fan_out_rate_limit  = nil  # {n, window_ms}
          # Synthesized barrier block — created by `parallel <name>`
          # expansion. Has no interface; the orchestrator special-cases
          # it as a no-op aggregator over its members' outputs. Honest
          # blocks have @barrier_for == nil.
          @barrier_for = nil
          @barrier_join_strategy = nil
          # Agentic-mode controls — only meaningful on `interface llm`
          # blocks. When @agentic is true, the LLM caller switches to
          # multi-turn tool-use against the listed @allowed_tools, with
          # @tool_call_limit as a hard ceiling on round-trips.
          @agentic = false
          @allowed_tools = []
          @tool_call_limit = nil
          # MCP-iface refs the agentic loop should pull tool lists from.
          # Each name must resolve to an `interface mcp <name>`. Tools
          # arrive in the registry namespaced as `<iface>.<tool>`.
          @mcp_refs = []
          # Per-block hard cost cap. When the per-attempt cost would
          # push runs.cost_usd above this value, the block fails with
          # error_type="cost_cap_exceeded".
          @max_cost_usd = nil
        end

        attr_accessor :agentic, :tool_call_limit
        attr_reader :allowed_tools, :mcp_refs

        def pause?
          !@pause_reason.nil?
        end

        def fan_out?
          !@fan_out_from.nil? && !@fan_out_into.nil?
        end

        def barrier?
          !@barrier_for.nil?
        end
      end

      # Named artifact handed from one block to another. The downstream
      # block declares `input from <upstream_block>.<relpath>`; the
      # orchestrator copies the archived file into /prouter/inputs/<local>
      # and exposes its path via env PROUTER_INPUT_<UPCASE(local)>.
      # `local` is the basename of <relpath> minus its last extension —
      # `model.pkl` -> `model`, `metrics.json` -> `metrics`. The validator
      # rejects two inputs in the same block that derive the same local.
      class ArtifactInput
        attr_accessor :from_block, :from_artifact, :line

        def initialize(from_block:, from_artifact:, line:)
          @from_block = from_block
          @from_artifact = from_artifact
          @line = line
        end

        def local_name
          File.basename(@from_artifact, ".*")
        end
      end

      class ProcessRoute
        attr_accessor :from_block, :to_block, :on_failure, :shutdown, :line
        attr_reader :matches

        ON_FAILURE_VALUES = %w[stop continue].freeze

        def initialize(from_block:, to_block:, line:)
          @from_block = from_block
          @to_block = to_block
          @line = line
          @on_failure = "stop"
          @shutdown = false
          @matches = []
        end
      end

      class GlobalRoute
        attr_accessor :interface_name, :process_name, :line
        attr_reader :matches

        def initialize(interface_name:, process_name:, line:)
          @interface_name = interface_name
          @process_name = process_name
          @line = line
          @matches = []
        end
      end

      class Match
        attr_accessor :path, :operator, :values, :line

        # Single-value operators take exactly one value, multi-value (`in`) takes
        # a list, `exists` takes none.
        OPERATORS = %w[eq neq gt gte lt lte exists in].freeze
        UNARY_OPERATORS = %w[exists].freeze
        MULTI_VALUE_OPERATORS = %w[in].freeze

        def initialize(path:, operator:, values:, line:)
          @path = path
          @operator = operator
          @values = values
          @line = line
        end
      end

      # A contract validates a block's output JSON against a set of
      # constraints declared in `contract <name> ... exit` at the top level.
      # Multiple lines for the same path accumulate constraints into a
      # single Requirement: `require x type integer` + `require x min 0` +
      # `require x max 100` collapses to one Requirement with all three.
      class Contract
        ON_VIOLATION_VALUES = %w[fail retry warn].freeze

        attr_accessor :name, :on_violation, :line
        attr_reader :requirements

        def initialize(name:, line:)
          @name = name
          @line = line
          @on_violation = "fail"
          @requirements = []
        end

        # Look up an existing requirement for `path`, or create a new one.
        # Optional/required is monotonic: a single `require` line on any
        # of the accumulating lines marks the path as required.
        def upsert_requirement(path:, required:, line:)
          existing = @requirements.find { |r| r.path == path }
          if existing
            existing.required = true if required
            existing
          else
            r = Requirement.new(path: path, required: required, line: line)
            @requirements << r
            r
          end
        end
      end

      class Requirement
        # Type constraint values accepted in `type <T>`. nil means "any".
        TYPES = %w[integer number string boolean array object].freeze
        # Built-in formats; `regex <pattern>` covers the escape hatch.
        FORMATS = %w[email uri uuid iso8601].freeze

        attr_accessor :path, :required, :type, :min, :max,
                      :length, :min_length, :max_length,
                      :format, :pattern, :enum, :line

        def initialize(path:, required:, line:)
          @path = path
          @required = required
          @line = line
          @type = nil
          @min = nil
          @max = nil
          @length = nil
          @min_length = nil
          @max_length = nil
          @format = nil
          @pattern = nil
          @enum = nil
        end

        # True iff at least one constraint beyond presence is declared.
        def has_constraints?
          !type.nil? || !min.nil? || !max.nil? || !length.nil? ||
            !min_length.nil? || !max_length.nil? || !format.nil? ||
            !pattern.nil? || !enum.nil?
        end
      end
    end
  end
end
