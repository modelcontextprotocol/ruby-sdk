# frozen_string_literal: true

require "test_helper"

class BaseMetadataTest < Minitest::Test
  # Test instance-level BaseMetadata (Resource, ResourceTemplate, Prompt::Argument)
  def test_resource_display_name_with_title
    resource = MCP::Resource.new(uri: "file:///test", name: "test_resource", title: "Test Resource")
    assert_equal("Test Resource", resource.display_name)
  end

  def test_resource_display_name_without_title
    resource = MCP::Resource.new(uri: "file:///test", name: "test_resource")
    assert_equal("test_resource", resource.display_name)
  end

  def test_resource_template_display_name_with_title
    template = MCP::ResourceTemplate.new(uri_template: "file:///{name}", name: "test_template", title: "Test Template")
    assert_equal("Test Template", template.display_name)
  end

  def test_resource_template_display_name_without_title
    template = MCP::ResourceTemplate.new(uri_template: "file:///{name}", name: "test_template")
    assert_equal("test_template", template.display_name)
  end

  def test_prompt_argument_display_name_with_title
    argument = MCP::Prompt::Argument.new(name: "test_arg", title: "Test Argument")
    assert_equal("Test Argument", argument.display_name)
  end

  def test_prompt_argument_display_name_without_title
    argument = MCP::Prompt::Argument.new(name: "test_arg")
    assert_equal("test_arg", argument.display_name)
  end

  # Test class-level BaseMetadata (Tool, Prompt)
  def test_tool_display_name_with_annotations_title
    tool_class = Class.new(MCP::Tool) do
      tool_name "test_tool"
      title "Tool Title"
      annotations(title: "Annotations Title")
    end

    assert_equal("Annotations Title", tool_class.display_name)
  end

  def test_tool_display_name_with_title_only
    tool_class = Class.new(MCP::Tool) do
      tool_name "test_tool"
      title "Tool Title"
    end

    assert_equal("Tool Title", tool_class.display_name)
  end

  def test_tool_display_name_with_name_only
    tool_class = Class.new(MCP::Tool) do
      tool_name "test_tool"
    end

    assert_equal("test_tool", tool_class.display_name)
  end

  def test_prompt_display_name_with_title
    prompt_class = Class.new(MCP::Prompt) do
      prompt_name "test_prompt"
      title "Prompt Title"
    end

    assert_equal("Prompt Title", prompt_class.display_name)
  end

  def test_prompt_display_name_without_title
    prompt_class = Class.new(MCP::Prompt) do
      prompt_name "test_prompt"
    end

    assert_equal("test_prompt", prompt_class.display_name)
  end

  def test_title_method_still_works_on_tool
    tool_class = Class.new(MCP::Tool) do
      tool_name "test_tool"
      title "My Tool"
    end

    assert_equal("My Tool", tool_class.title)
  end

  def test_title_method_still_works_on_prompt
    prompt_class = Class.new(MCP::Prompt) do
      prompt_name "test_prompt"
      title "My Prompt"
    end

    assert_equal("My Prompt", prompt_class.title)
  end
end
