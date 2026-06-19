---
layout: default
title: Installation
nav_order: 2
---

# Installation

Add this line to your application's Gemfile:

```ruby
gem 'mcp'
```

And then execute:

```console
$ bundle install
```

Or install it yourself as:

```console
$ gem install mcp
```

You may need to add additional dependencies depending on which features you wish to access. For example, the HTTP client transport requires the `faraday` gem:

```ruby
gem 'mcp'
gem 'faraday', '>= 2.0'
```
