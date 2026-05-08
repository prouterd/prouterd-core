module Prouterd
  module Iface
    # Live-discovered MCP tool descriptor, sourced from a
    # `tools/list` response. Substitutes for AST::Tool in the agentic
    # tool array — same surface that LlmAgentic#tool_definitions
    # consumes (`name`, `description`, schema) plus `full_name` so
    # the dispatcher can route by `<iface>.<tool>` form.
    #
    # Lives outside AST because it's runtime-resolved; AST nodes
    # represent declared (parsed) configuration, while this comes
    # from the live JSON-RPC session at trigger time.
    McpToolRef = Struct.new(
      :iface_name, :tool_name, :full_name,
      :description, :input_schema,
      keyword_init: true
    ) do
      # The agentic loop treats `name` as the wire identifier the
      # model sees in tool_use blocks. For MCP tools that's the full
      # `<iface>.<tool>` form — but llm_agentic.rb prefers
      # `tool_facing_name(t)` (which calls full_name when present)
      # so we still expose `name` for any legacy reader.
      def name; full_name; end
      def args; (input_schema && input_schema["required"]) || []; end
    end
  end
end
