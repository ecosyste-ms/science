require "test_helper"

class ProjectDependencyTest < ActiveSupport::TestCase
  test "retains an unresolved package coordinate" do
    project = Project.create!(url: "https://github.com/example/unresolved-dependency")

    dependency = ProjectDependency.create!(
      project: project,
      ecosystem: "RubyGems",
      package_name: "rails",
      purl: "pkg:gem/rails@8.1.0",
      direct: true,
      metadata: {
        "occurrences" => [
          { "filepath" => "Gemfile", "requirements" => "~> 8.1" },
        ],
      }
    )

    assert_nil dependency.package
    assert_equal "pkg:gem/rails", dependency.purl
    assert_equal "rubygems", dependency.ecosystem
    assert_equal "Gemfile", dependency.metadata.dig("occurrences", 0, "filepath")
  end

  test "retains package identity when a resolved package is removed" do
    project = Project.create!(url: "https://github.com/example/resolved-dependency")
    registry = PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "rails",
      purl: "pkg:gem/rails"
    )
    dependency = ProjectDependency.create!(
      project: project,
      package: package,
      ecosystem: "rubygems",
      package_name: "rails",
      purl: package.purl,
      direct: true
    )

    package.destroy!

    assert_nil dependency.reload.package
    assert_equal "pkg:gem/rails", dependency.purl
  end
end
