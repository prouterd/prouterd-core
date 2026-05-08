require "shellwords"

module Prouterd
  module Iface
    module Mcp
      # Resolves an `interface mcp` server-spec (`{kind, spec}`) into
      # an argv array suitable for `Process.spawn`. Four kinds:
      #
      #   npx — `npx -y <spec>`         (auto-confirms first install)
      #   uvx — `uv tool run <spec>`    (uv 0.4+; falls back to `uvx <spec>`)
      #   bin — direct exec of an absolute path
      #   raw — shell-tokenised argv via Shellwords.split
      #
      # No shell interpolation. The resolver returns argv; the caller
      # threads env vars separately. Templated `{{...}}` in `spec`
      # is rejected by the validator for `raw` (other kinds simply
      # don't template their spec).
      module ServerCommand
        class ResolveError < StandardError; end

        # Returns argv (Array<String>). Raises ResolveError for empty
        # specs / unknown kinds. The caller is responsible for spawning.
        def self.resolve(server_field)
          unless server_field.is_a?(Hash) && server_field["kind"] && server_field["spec"]
            raise ResolveError, "server field must be {kind, spec}, got #{server_field.inspect}"
          end

          kind = server_field["kind"].to_s
          spec = server_field["spec"].to_s
          raise ResolveError, "server spec is empty" if spec.empty?

          case kind
          when "npx" then ["npx", "-y", spec]
          when "uvx"
            # Newer uv prefers `uv tool run`; the standalone `uvx`
            # binary is still shipped for backwards compat. Pick
            # whichever is on PATH.
            executable_on_path?("uv") ? ["uv", "tool", "run", spec] : ["uvx", spec]
          when "bin"
            unless spec.start_with?("/")
              raise ResolveError, "server bin spec must be absolute path, got '#{spec}'"
            end
            [spec]
          when "raw"
            argv = Shellwords.split(spec)
            raise ResolveError, "server raw spec is empty after shell-split" if argv.empty?
            argv
          else
            raise ResolveError, "unknown server kind '#{kind}'"
          end
        end

        # `prouter validate`-time helper. Returns nil on success, a
        # human-readable warning string when something looks off.
        # Apply-time check, NOT a hard error — the daemon may run on a
        # different host with different PATH than the one validating.
        def self.warn_if_unresolvable(server_field)
          return nil unless server_field.is_a?(Hash)

          case server_field["kind"]
          when "npx"
            executable_on_path?("npx") ? nil : "`npx` is not on PATH on this host"
          when "uvx"
            (executable_on_path?("uv") || executable_on_path?("uvx")) ? nil : "`uv` / `uvx` is not on PATH on this host"
          when "bin"
            path = server_field["spec"].to_s
            return "bin spec must be absolute" unless path.start_with?("/")
            return "bin '#{path}' does not exist"   unless File.exist?(path)
            return "bin '#{path}' is not executable" unless File.executable?(path)
            nil
          when "raw"
            "`server raw` cannot be validated until daemon start"
          end
        end

        def self.executable_on_path?(name)
          return false if name.nil? || name.empty?

          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
            full = File.join(dir, name)
            File.file?(full) && File.executable?(full)
          end
        end
      end
    end
  end
end
