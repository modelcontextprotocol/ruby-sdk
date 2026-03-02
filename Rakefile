# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.ruby_opts = ["-W0", "-W:deprecated"]
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: [:rubocop, :test, :conformance]

desc "Run MCP conformance tests (PORT, SCENARIO, SPEC_VERSION, VERBOSE)"
task :conformance do |t|
  next unless npx_available?(t.name)

  require_relative "conformance/runner"

  options = {}
  options[:port] = Integer(ENV["PORT"]) if ENV["PORT"]
  options[:scenario] = ENV["SCENARIO"] if ENV["SCENARIO"]
  options[:spec_version] = ENV["SPEC_VERSION"] if ENV["SPEC_VERSION"]
  options[:verbose] = true if ENV["VERBOSE"]

  Conformance::Runner.new(**options).run
end

desc "List available conformance scenarios"
task :conformance_list do |t|
  next unless npx_available?(t.name)

  system("npx", "--yes", "@modelcontextprotocol/conformance", "list", "--server")
end

desc "Start the conformance server (PORT)"
task :conformance_server do
  require_relative "conformance/server"

  options = {}
  options[:port] = Integer(ENV["PORT"]) if ENV["PORT"]

  Conformance::Server.new(**options).start
end

def npx_available?(task_name)
  return true if system("which", "npx", out: File::NULL, err: File::NULL)

  warn("Skipping #{task_name}: npx is not installed. Install Node.js to run this task: https://nodejs.org/")
  false
end
