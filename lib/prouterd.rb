# frozen_string_literal: true

require_relative "prouterd/version"
require_relative "prouterd/logger"
require_relative "prouterd/util/duration_parser"
require_relative "prouterd/util/templater"
require_relative "prouterd/util/semantic_diff"
require_relative "prouterd/config/errors"
require_relative "prouterd/config/token"
require_relative "prouterd/config/lexer"
require_relative "prouterd/config/ast"
# Runner and Iface plugins must be registered before the parser/validator/
# renderer use their Registries to dispatch on `type <name>` (block) and
# `interface <type>` (interface).
require_relative "prouterd/runner"
require_relative "prouterd/iface"
require_relative "prouterd/config/parser"
require_relative "prouterd/config/validator"
require_relative "prouterd/config/renderer"
require_relative "prouterd/storage"
require_relative "prouterd/events"
require_relative "prouterd/control_plane"
require_relative "prouterd/runtime"
require_relative "prouterd/shell"
require_relative "prouterd/api"

module Prouterd
end
