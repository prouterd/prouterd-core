module Prouterd
  module Config
    module AST
      # Root of the parsed config. Top-level sections live here in declaration order.
      class Document
        attr_accessor :router
        attr_reader :secrets, :policies, :queues, :interfaces, :processes, :global_routes

        def initialize
          @router = nil
          @secrets = []
          @policies = []
          @queues = []
          @interfaces = []
          @processes = []
          @global_routes = []
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

        BACKOFF_TYPES = %w[fixed linear exponential].freeze

        def initialize(name:, line:)
          @name = name
          @line = line
          @retry_attempts = nil
          @retry_backoff = nil
          @retry_initial_delay_ms = nil
          @retry_max_delay_ms = nil
          @timeout_ms = nil
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

        # Webhook-only fields
        attr_accessor :path, :method, :auth

        # Cron-only fields
        attr_accessor :schedule, :timezone

        TYPES = %w[webhook manual cron].freeze

        def initialize(type:, name:, line:)
          @type = type
          @name = name
          @line = line
          @shutdown = false
          @path = nil
          @method = nil
          @auth = nil
          @schedule = nil
          @timezone = nil
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
        attr_accessor :name, :description, :queue_name, :shutdown, :line
        attr_reader :blocks, :routes

        def initialize(name:, line:)
          @name = name
          @line = line
          @description = nil
          @queue_name = nil
          @shutdown = false
          @blocks = []
          @routes = []
        end

        def block(name)
          blocks.find { |b| b.name == name }
        end
      end

      class Block
        # Common block fields (apply regardless of execution_type):
        attr_accessor :name, :timeout_ms, :retry_policy_name, :contract_name,
                      :input, :output, :shutdown, :line, :execution_type
        attr_reader :secret_names

        # Docker-only fields:
        attr_accessor :image, :command, :network, :pull, :user, :memory, :cpu

        # Shell-only fields:
        attr_accessor :shell_exec, :shell_cwd, :shell_path
        attr_reader :shell_env

        NETWORK_VALUES = %w[on off].freeze
        EXECUTION_TYPES = %w[docker shell].freeze
        PULL_VALUES = %w[never if-missing always].freeze

        def initialize(name:, line:)
          @name = name
          @line = line
          @execution_type = nil
          @timeout_ms = nil
          @retry_policy_name = nil
          @contract_name = nil
          @secret_names = []
          @input = nil
          @output = nil
          @shutdown = false

          # Docker
          @image = nil
          @command = nil
          @network = "on"
          @pull = nil
          @user = nil
          @memory = nil
          @cpu = nil

          # Shell
          @shell_exec = nil
          @shell_cwd = nil
          @shell_path = nil
          @shell_env = {}
        end

        def docker?
          execution_type == "docker"
        end

        def shell?
          execution_type == "shell"
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
    end
  end
end
