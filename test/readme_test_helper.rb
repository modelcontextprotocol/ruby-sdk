# frozen_string_literal: true

module ReadmeTestHelper
  private

  # Extracts a code snippet from the README.md file by its "SNIPPET ID" comment and language
  def extract_readme_code_snippet(id, language: "ruby")
    snippet = readme_content[/<!-- SNIPPET ID: #{id} -->\n```#{language}\n(.*?)\n```/m, 1]
    assert_not_nil(snippet, "Could not find code snippet with ID #{id}")
    snippet
  end

  def readme_content = File.read(File.join(project_root, "README.md"))
  def project_root = File.expand_path("..", __dir__)
end
