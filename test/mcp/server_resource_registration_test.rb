# frozen_string_literal: true

require "test_helper"

module MCP
  # A resource or a resource template registered without a member the spec requires is refused where it is registered.
  class ServerResourceRegistrationTest < ActiveSupport::TestCase
    setup do
      @complete = Resource.new(uri: "file:///a.txt", name: "a")
      @template = ResourceTemplate.new(uri_template: "file:///{path}", name: "files")
    end

    test "a resource without a name or without a uri is refused by the constructor" do
      nameless = Class.new(Resource) { uri "file:///b.txt" }
      without_uri = Resource.define(name: "c")

      error = assert_raises(ArgumentError) { Server.new(name: "test", resources: [@complete, nameless]) }
      assert_equal "A resource must have uri and name (file:///b.txt): name is missing.", error.message

      error = assert_raises(ArgumentError) { Server.new(name: "test", resources: [without_uri]) }
      assert_equal "A resource must have uri and name (c): uri is missing.", error.message

      error = assert_raises(ArgumentError) { Server.new(name: "test", resources: [Resource.new(uri: nil, name: nil)]) }
      assert_equal "A resource must have uri and name: uri, name are missing.", error.message
    end

    class NamedByItsClassResource < Resource
      uri "file:///named.txt"
    end

    test "a class-based resource named by its class is complete" do
      server = Server.new(name: "test", resources: [NamedByItsClassResource])

      assert_equal ["named_by_its_class_resource"], server.resources.map { |resource| resource.to_h[:name] }
    end

    test "a resource template without a name or without a uri template is refused by the constructor" do
      nameless = Class.new(ResourceTemplate) { uri_template "file:///{b}" }

      error = assert_raises(ArgumentError) { Server.new(name: "test", resource_templates: [@template, nameless]) }
      assert_equal "A resource template must have uriTemplate and name (file:///{b}): name is missing.", error.message

      error = assert_raises(ArgumentError) do
        Server.new(name: "test", resource_templates: [ResourceTemplate.new(uri_template: nil, name: "c")])
      end
      assert_equal "A resource template must have uriTemplate and name (c): uriTemplate is missing.", error.message
    end

    test "the setters refuse an incomplete definition and keep what was registered" do
      server = Server.new(name: "test", resources: [@complete], resource_templates: [@template])

      assert_raises(ArgumentError) { server.resources = [Resource.new(uri: "file:///b.txt", name: nil)] }
      assert_raises(ArgumentError) { server.resource_templates = [ResourceTemplate.new(uri_template: "file:///{b}", name: nil)] }

      assert_equal [@complete], server.resources
      assert_equal [@template], server.resource_templates
      assert_equal ["file:///a.txt"], server.instance_variable_get(:@resource_index).keys
    end

    test "a template without both members names both" do
      error = assert_raises(ArgumentError) do
        Server.new(name: "test", resource_templates: [ResourceTemplate.new(uri_template: nil, name: nil)])
      end

      assert_equal "A resource template must have uriTemplate and name: uriTemplate, name are missing.", error.message
    end

    test "define_resource and define_resource_template refuse an incomplete definition and register nothing" do
      server = Server.new(name: "test")

      assert_raises(ArgumentError) { server.define_resource(name: "no_uri") { [] } }
      assert_raises(ArgumentError) { server.define_resource(uri: "file:///b.txt") { [] } }
      assert_raises(ArgumentError) { server.define_resource_template(name: "no_template") { [] } }

      assert_empty server.resources
      assert_empty server.resource_templates
      assert_empty server.instance_variable_get(:@resource_index)
    end

    test "complete definitions are registered as before" do
      server = Server.new(name: "test", resources: [@complete], resource_templates: [@template])
      server.define_resource(uri: "file:///d.txt", name: "d") { [] }
      server.define_resource_template(uri_template: "file:///{d}", name: "d_files") { [] }
      server.resources = server.resources + [Resource.new(uri: "file:///e.txt", name: "e")]
      server.resource_templates = server.resource_templates + [ResourceTemplate.new(uri_template: "file:///{e}", name: "e_files")]

      assert_equal ["a", "d", "e"], server.resources.map { |resource| resource.to_h[:name] }
      assert_equal ["files", "d_files", "e_files"], server.resource_templates.map { |template| template.to_h[:name] }
    end
  end
end
