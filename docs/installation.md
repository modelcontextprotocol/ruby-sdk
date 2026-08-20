---
layout: default
title: Installation
nav_order: 2
permalink: /installation/
redirect_from:
  - /installation.html
---

# Installation

Install the gem and any optional dependencies for the features you use.

## Requirements

Ruby 2.7.0 or later.

## Installing the Gem

Add this line to your application's Gemfile:

```ruby
gem "mcp"
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
gem "mcp"
gem "faraday", ">= 2.0"
```
