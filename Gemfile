# frozen_string_literal: true

source "https://rubygems.org"

# Specify runtime dependencies in the gemspec
gemspec

# Specify development dependencies below
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false
gem "rubocop-shopify", require: false

gem "puma", ">= 5.0.0"
gem "rack", ">= 2.0.0"
gem "rackup", ">= 2.1.0"

gem "activesupport"
gem "debug"
gem "rake", "~> 13.0"
gem "sorbet-static-and-runtime"

group :test do
  gem "faraday", ">= 2.0"
  gem "minitest", "~> 5.1", require: false
  gem "mocha"
  gem "webmock"
end
