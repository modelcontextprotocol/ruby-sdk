# frozen_string_literal: true

require_relative "lib/mcp/version"

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

  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    %x(git ls-files -z).split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("json_rpc_handler", "~> 0.1")
  spec.add_dependency("rack", ">= 2.0.0")
  spec.add_development_dependency("activesupport")
  spec.add_development_dependency("puma", ">= 5.0.0")
  spec.add_development_dependency("sorbet-static-and-runtime")
end
