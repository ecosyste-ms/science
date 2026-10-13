require "test_helper"

class RepositoryMetadataTest < ActiveSupport::TestCase
  test "extracts plain prose without front matter badges code or tables" do
    readme = "---\ntitle: Example\n---\n# Heading\n\n[![Build](badge.svg)](https://example.org)\n\n```python\nprint('This is code and should never become a project description')\n```\n\nThis **tool** compares scientific results across several independent datasets.\n"
    metadata = RepositoryMetadata.new(readme: readme, brief: {})
    assert_equal "Example", metadata.name
    assert_equal "This tool compares scientific results across several independent datasets.", metadata.description
    assert_equal metadata.attributes, metadata.attributes
  end

  test "unsafe or invalid YAML does not prevent extracting the body" do
    ["x: !ruby/object:Object {}", "x: *missing", "[unclosed"].each do |yaml|
      metadata = RepositoryMetadata.new(readme: "---\n#{yaml}\n---\n# Example\n\nA useful description of a scientific repository and its purpose.\n", brief: {})
      assert_empty metadata.frontmatter
      assert_equal "Example", metadata.name
      assert metadata.description.present?
    end
  end

  test "ignores generic first headings and code comments when choosing names" do
    metadata = RepositoryMetadata.new(readme: "# Model Overview\n\n# Usage", brief: {})
    assert_nil metadata.name
    metadata = RepositoryMetadata.new(readme: "Load the model.\n```python\n# Download from the Hub\n```", brief: {})
    assert_nil metadata.name
    metadata = RepositoryMetadata.new(readme: "## SPLADE CoCondenser SelfDistil", brief: {})
    assert_equal "SPLADE CoCondenser SelfDistil", metadata.name
  end

  test "human languages do not become source languages" do
    metadata = RepositoryMetadata.new(readme: "---\nlanguage: en\n---\n# Weights", brief: { "languages" => nil })
    assert_nil metadata.attributes["language"]
    assert_nil metadata.description
  end
end
