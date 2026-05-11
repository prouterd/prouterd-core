# frozen_string_literal: true

module Prouterd
  module Iface
    # Process-global registry of `Iface::Plugin` subclasses. Mirrors
    # `Runner::Registry`. Each plugin file calls `Registry.register!(MyPlugin)`
    # at load time. Lookups are by DSL `interface <type>` keyword.
    module Registry
      class DuplicateError < StandardError; end
      class UnknownTypeError < StandardError; end

      module_function

      def register(plugin)
        store[plugin.type_name] = plugin
      end

      # Allow re-registering the same plugin (idempotent). Raises if a
      # *different* class claims an existing type name.
      def register!(plugin)
        existing = store[plugin.type_name]
        if existing && existing != plugin
          raise DuplicateError,
                "interface type '#{plugin.type_name}' already registered by #{existing}"
        end
        store[plugin.type_name] = plugin
      end

      def lookup(type_name)
        store[type_name.to_s]
      end

      def lookup!(type_name)
        store[type_name.to_s] or
          raise UnknownTypeError, "no interface plugin registered for type '#{type_name}'"
      end

      def types
        store.keys
      end

      def inbound_types
        store.values.select(&:inbound?).map(&:type_name)
      end

      def outbound_types
        store.values.select(&:outbound?).map(&:type_name)
      end

      def all
        store.values
      end

      def each(&block)
        return store.values.each unless block

        store.values.each(&block)
      end

      def clear!
        @store = {}
      end

      def store
        @store ||= {}
      end
    end
  end
end
