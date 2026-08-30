require "test_helper"

class ProjectDependencyIndexerTest < ActiveSupport::TestCase
  test "reconciles direct dependencies and records manifest occurrences" do
    project = Project.create!(
      url: "https://github.com/example/dependency-indexer",
      dependencies: [
        manifest(
          "requirements.txt",
          [
            dependency("Django", requirements: ">=5", optional: true),
            dependency("transitive", direct: false),
            dependency("", requirements: "*"),
          ]
        ),
        manifest(
          "docs/requirements.txt",
          [dependency("Django", requirements: "==5.2")]
        ),
      ]
    )
    stale = ProjectDependency.create!(
      project: project,
      ecosystem: "pypi",
      package_name: "old-package",
      direct: true
    )

    result = Project.sync_dependencies(limit: 1)

    assert_equal 1, result[:selected]
    assert_equal 1, result[:indexed]
    assert_equal 1, result[:dependencies]
    assert_equal 1, result[:skipped]
    assert_not ProjectDependency.exists?(stale.id)
    indexed = project.project_dependencies.reload.sole
    assert_equal "pypi", indexed.ecosystem
    assert_equal "Django", indexed.package_name
    assert indexed.direct?
    assert_equal "repos_manifests", indexed.metadata.fetch("source")
    assert_equal ["docs/requirements.txt", "requirements.txt"],
      indexed.metadata.fetch("occurrences").pluck("filepath")
    assert project.reload.dependencies_indexed_at.present?
    assert_nil project.dependencies_index_error
  end

  test "canonicalizes a dependency purl without discarding qualifiers" do
    project = Project.create!(
      url: "https://github.com/example/dependency-purl",
      dependencies: [
        manifest(
          "package.json",
          [
            dependency(
              "example",
              ecosystem: "npm",
              purl: "pkg:npm/example@1.2.3?repository_url=https://npm.example.com"
            ),
          ]
        ),
      ]
    )

    Project.sync_dependencies(limit: 1)

    assert_equal(
      "pkg:npm/example?repository_url=https://npm.example.com",
      project.project_dependencies.reload.sole.purl
    )
  end

  test "uses Brief when repos manifests have no direct dependency data" do
    project = Project.create!(
      url: "https://github.com/example/dependency-brief",
      dependencies: [],
      brief: {
        "version" => "0.12.1",
        "dependencies" => [
          {
            "name" => "rails",
            "version" => "~> 8.1",
            "purl" => "pkg:gem/rails",
            "scope" => "runtime",
            "direct" => true,
          },
          {
            "name" => "rack",
            "purl" => "pkg:gem/rack@3.2.0",
            "scope" => "runtime",
            "direct" => false,
          },
        ],
      }
    )

    Project.sync_dependencies(limit: 1)

    indexed = project.project_dependencies.reload.sole
    assert_equal "brief", indexed.metadata.fetch("source")
    assert_equal "gem", indexed.ecosystem
    assert_equal "rails", indexed.package_name
    assert_equal "pkg:gem/rails", indexed.purl
    assert_equal "~> 8.1",
      indexed.metadata.dig("occurrences", 0, "requirements")
  end

  test "does not select a project before either source has dependency data" do
    project = Project.create!(
      url: "https://github.com/example/dependency-not-collected",
      brief: { "version" => "0.12.0", "languages" => [] }
    )

    result = Project.sync_dependencies(limit: 1)

    assert_equal 0, result[:selected]
    assert_nil project.reload.dependencies_indexed_at
    assert_empty project.project_dependencies
  end

  test "records an empty repos result once while waiting for future Brief data" do
    project = Project.create!(
      url: "https://github.com/example/dependency-empty",
      dependencies: []
    )

    first_result = Project.sync_dependencies(limit: 1)
    second_result = Project.sync_dependencies(limit: 1)

    assert_equal 1, first_result[:indexed]
    assert_equal 0, first_result[:dependencies]
    assert_equal 0, second_result[:selected]
    assert project.reload.dependencies_indexed_at.present?
    assert_empty project.project_dependencies
  end

  test "prefers repos manifests when both sources have direct dependencies" do
    project = Project.create!(
      url: "https://github.com/example/dependency-source-priority",
      dependencies: [manifest("requirements.txt", [dependency("numpy")])],
      brief: {
        "dependencies" => [
          {
            "name" => "scipy",
            "purl" => "pkg:pypi/scipy",
            "scope" => "runtime",
            "direct" => true,
          },
        ],
      }
    )

    Project.sync_dependencies(limit: 1)

    indexed = project.project_dependencies.reload.sole
    assert_equal "numpy", indexed.package_name
    assert_equal "repos_manifests", indexed.metadata.fetch("source")
  end

  test "limits each run and skips projects already indexed" do
    first = Project.create!(
      url: "https://github.com/example/dependency-first",
      dependencies: [manifest("Gemfile", [dependency("rails", ecosystem: "rubygems")])]
    )
    second = Project.create!(
      url: "https://github.com/example/dependency-second",
      dependencies: [manifest("Gemfile", [dependency("rake", ecosystem: "rubygems")])]
    )

    first_result = Project.sync_dependencies(limit: 1)
    second_result = Project.sync_dependencies(limit: 1)
    final_result = Project.sync_dependencies(limit: 1)

    assert_equal 1, first_result[:selected]
    assert_equal 1, second_result[:selected]
    assert_equal 0, final_result[:selected]
    assert first.reload.dependencies_indexed_at.present?
    assert second.reload.dependencies_indexed_at.present?
  end

  test "rechecks indexing state after locking a selected project" do
    project = Project.create!(
      url: "https://github.com/example/dependency-concurrent",
      dependencies: [manifest("Gemfile", [dependency("rails", ecosystem: "rubygems")])],
      dependencies_indexed_at: Time.current
    )

    result = ProjectDependencyIndexer.new(project).sync!

    assert_not result[:indexed]
    assert_empty project.project_dependencies.reload
  end

  test "quarantines invalid manifest payloads until explicitly retried" do
    Rails.logger.stubs(:error)
    project = Project.create!(
      url: "https://github.com/example/dependency-error",
      dependencies: { "unexpected" => true }
    )

    first_result = Project.sync_dependencies(limit: 1)
    second_result = Project.sync_dependencies(limit: 1)
    retry_result = Project.sync_dependencies(limit: 1, retry_errors: true)

    assert_equal 1, first_result[:failed]
    assert_equal 0, second_result[:selected]
    assert_equal 1, retry_result[:failed]
    assert_match "dependencies must be an array", project.reload.dependencies_index_error
    assert_nil project.dependencies_indexed_at
  end

  test "rejects a batch above the maximum" do
    error = assert_raises(ArgumentError) do
      Project.sync_dependencies(limit: ProjectDependencyIndexer::MAX_LIMIT + 1)
    end

    assert_equal "limit must be between 1 and 1000", error.message
  end

  def manifest(filepath, dependencies, ecosystem: "pypi", kind: "manifest")
    {
      "ecosystem" => ecosystem,
      "filepath" => filepath,
      "kind" => kind,
      "dependencies" => dependencies,
    }
  end

  def dependency(
    package_name,
    ecosystem: "pypi",
    requirements: "*",
    direct: true,
    kind: "runtime",
    optional: false,
    purl: nil
  )
    {
      "package_name" => package_name,
      "ecosystem" => ecosystem,
      "requirements" => requirements,
      "direct" => direct,
      "kind" => kind,
      "optional" => optional,
      "purl" => purl,
    }.compact
  end
end
