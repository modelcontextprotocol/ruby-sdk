# frozen_string_literal: true

require_relative "lib/mcp/shared/version"

Gem::Specification.new do |spec|
  spec.name          = "mcp"
  spec.version       = MCP::VERSION
  spec.authors       = ["Model Context Protocol"]
  spec.email         = ["mcp-support@anthropic.com"]

  spec.summary       = "The official Ruby SDK for Model Context Protocol servers and clients"
  spec.description   = spec.summary
  spec.homepage      = "https://github.com/modelcontextprotocol/ruby-sdk"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob("lib/**/*.rb").reject { |f| f.match(%r{^(test|spec|features)/}) }

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("json_rpc_handler", "~> 0.1")
  spec.add_dependency("json-schema", ">= 4.1")
end
