require "test_helper"

class PackageRegistryTest < ActiveSupport::TestCase
  test "uses the ecosystem default when a dependency has no registry" do
    registry = PackageRegistry.create!(
      name: "proxy.golang.org",
      url: "https://proxy.golang.org/",
      ecosystem: "go",
      purl_type: "golang",
      default: true
    )

    assert_equal registry, PackageRegistry.for_dependency(
      ecosystem: "Go",
      purl_type: "golang"
    )
    assert_equal "https://proxy.golang.org", registry.url
    assert_equal "go", registry.ecosystem
  end

  test "uses the Purl default registry when no ecosystem default exists" do
    registry = PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem"
    )

    assert_equal registry, PackageRegistry.for_dependency(
      ecosystem: "unknown-ruby-source",
      purl_type: "gem"
    )
  end

  test "does not replace an unknown explicit registry with the default" do
    PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )

    assert_nil PackageRegistry.for_dependency(
      ecosystem: "rubygems",
      purl_type: "gem",
      repository_url: "https://gems.example.com"
    )
  end
end
