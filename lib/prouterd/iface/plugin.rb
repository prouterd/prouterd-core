module Prouterd
  module Iface
    # Subclass `Plugin` to add a new `interface` type. One plugin file
    # describes:
    #
    #   1. The DSL `interface <type> <name>` keyword that activates it.
    #   2. The fields that appear inside `interface ... exit`.
    #   3. Whether the interface is inbound (triggers a process — webhook,
    #      cron, manual) or outbound (called by a block — http, llm, ...).
    #
    # The framework drives parser/validator/renderer off this declaration —
    # adding a new interface type does NOT require touching any core file.
    #
    # Mirrors `Prouterd::Runner::Plugin`. The `Field` struct + `:string` /
    # `:enum` / `:command` field kinds are intentionally compatible so a
    # future refactor can share one base class.
    class Plugin
      Field = Struct.new(
        :name, :kind, :required, :enum, :default, :description,
        keyword_init: true
      ) do
        def dsl_keyword;  name.to_s; end
        def storage_key;  name.to_s; end
      end

      class << self
        # ----- DSL declaration -----

        # Required. The `interface <type>` keyword.
        def type(name)
          @type_name = name.to_s
        end

        def type_name
          @type_name or raise "Iface::Plugin #{self} missing `type \"...\"`"
        end

        # Required. Either :inbound (something fires it externally — webhook,
        # cron, manual) or :outbound (a block calls into it — http, llm, ...).
        def direction(d = nil)
          if d
            unless %i[inbound outbound].include?(d)
              raise "direction must be :inbound or :outbound, got #{d.inspect}"
            end
            @direction = d
          end
          @direction or raise "Iface::Plugin #{self} missing `direction :inbound|:outbound`"
        end

        def inbound?;  direction == :inbound;  end
        def outbound?; direction == :outbound; end

        # Declare a field. Order matters for the canonical renderer.
        #
        #   kind: :string       — single token, accepts word or quoted string
        #   kind: :enum         — single token, must match `enum:` list
        #   kind: :path         — :string + must start with '/'
        #   kind: :http_method  — :enum constrained to HTTP_METHODS, uppercased
        #   kind: :auth_bearer  — multi-token: `auth bearer secret <NAME>`
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

        # Per-plugin validation hook. Called by Config::Validator after the
        # required-field check. Plugins override to add cross-field invariants
        # (e.g. webhook-auth secret must exist in document.secrets).
        # Default: no-op.
        def validate(_iface, _document, _result); end
      end
    end
  end
end
