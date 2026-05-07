module Prouterd
  module Config
    module AST
      # Root of the parsed config. Top-level sections live here in declaration order.
      class Document
        attr_accessor :router
        attr_reader :secrets, :policies, :queues, :interfaces, :processes, :global_routes, :contracts

        def initialize
          @router = nil
          @secrets = []
          @policies = []
          @queues = []
          @interfaces = []
          @processes = []
          @global_routes = []
          @contracts = []
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
        attr_reader :retry_when_matches

        BACKOFF_TYPES = %w[fixed linear exponential].freeze

        def initialize(name:, line:)
          @name = name
          @line = line
          @retry_attempts = nil
          @retry_backoff = nil
          @retry_initial_delay_ms = nil
          @retry_max_delay_ms = nil
          @timeout_ms = nil
          # Optional `retry when <path> <op> <value>` conditions. Multiple
          # entries OR together — any one matching means the failure is
          # retryable. No entries means "retry on any failure".
          @retry_when_matches = []
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

      class Process
        attr_accessor :name, :description, :queue_name, :shutdown, :timeout_ms, :line
        attr_reader :blocks, :routes

        def initialize(name:, line:)
          @name = name
          @line = line
          @description = nil
          @queue_name = nil
          @shutdown = false
          @timeout_ms = nil
          @blocks = []
          @routes = []
        end

        def block(name)
          blocks.find { |b| b.name == name }
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
                      :interface_ref, :skip_when
        attr_reader :secret_names, :produces, :artifact_inputs

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
