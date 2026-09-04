require "test_helper"

class ProjectDependencyResolverTest < ActiveSupport::TestCase
  test "resolves a shared Purl identity once and links every dependency row" do
    registry = create_registry(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi"
    )
    first = create_dependency(
      "first",
      ecosystem: "pypi",
      package_name: "Django",
      purl: "pkg:pypi/Django"
    )
    second = create_dependency(
      "second",
      ecosystem: "pypi",
      package_name: "django",
      purl: "pkg:pypi/django"
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:resolved)
    assert_equal 2, result.fetch(:dependency_rows)
    assert_equal 1, result.fetch(:packages_created)
    package = Package.sole
    assert_equal registry, package.package_registry
    assert_equal "django", package.name
    assert_equal "pkg:pypi/django", package.purl
    assert_equal [package.id], [first.reload.package_id, second.reload.package_id].uniq
    assert first.package_resolution_attempted_at.present?
    assert_nil first.package_resolution_error
  end

  test "preserves scoped npm names from a Purl" do
    create_registry(
      name: "npmjs.org",
      url: "https://registry.npmjs.org",
      ecosystem: "npm",
      purl_type: "npm"
    )
    dependency = create_dependency(
      "npm",
      ecosystem: "npm",
      package_name: "@scope/name",
      purl: "pkg:npm/%40scope/name"
    )

    ProjectDependencyResolver.resolve_batch!(limit: 1)

    package = dependency.reload.package
    assert_equal "@scope/name", package.name
    assert_equal "@scope", package.namespace
    assert_equal "pkg:npm/%40scope/name", package.purl
  end

  test "builds a Maven Purl from a registry coordinate" do
    create_registry(
      name: "repo1.maven.org",
      url: "https://repo.maven.apache.org/maven2",
      ecosystem: "maven",
      purl_type: "maven"
    )
    dependency = create_dependency(
      "maven",
      ecosystem: "maven",
      package_name: "org.example:library"
    )

    ProjectDependencyResolver.resolve_batch!(limit: 1)

    package = dependency.reload.package
    assert_equal "org.example:library", package.name
    assert_equal "org.example", package.namespace
    assert_equal "pkg:maven/org.example/library", package.purl
  end

  test "creates a local package before external availability is known" do
    create_registry(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem"
    )
    dependency = create_dependency(
      "private-package",
      ecosystem: "rubygems",
      package_name: "internal-research-gem",
      purl: "pkg:gem/internal-research-gem"
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:resolved)
    assert_equal "pkg:gem/internal-research-gem", dependency.reload.package.purl
  end

  test "does not assign a Docker image from an unknown registry to Docker Hub" do
    Rails.logger.stubs(:error)
    create_registry(
      name: "hub.docker.com",
      url: "https://hub.docker.com",
      ecosystem: "docker",
      purl_type: "docker"
    )
    dependency = create_dependency(
      "quay-image",
      ecosystem: "docker",
      package_name: "quay.io/jupyter/base-notebook"
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:failed)
    assert_nil dependency.reload.package_id
    assert_match "no package registry for https://quay.io",
      dependency.package_resolution_error
  end

  test "detects an unknown registry embedded in a Docker Purl name" do
    Rails.logger.stubs(:error)
    create_registry(
      name: "hub.docker.com",
      url: "https://hub.docker.com",
      ecosystem: "docker",
      purl_type: "docker"
    )
    dependency = create_dependency(
      "quay-purl",
      ecosystem: "docker",
      package_name: "quay.io/jupyter/base-notebook",
      purl: "pkg:docker/quay.io%2Fjupyter%2Fbase-notebook"
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:failed)
    assert_nil dependency.reload.package_id
    assert_match "no package registry for https://quay.io",
      dependency.package_resolution_error
  end

  test "keeps the registry qualifier for a known non-default Docker registry" do
    create_registry(
      name: "hub.docker.com",
      url: "https://hub.docker.com",
      ecosystem: "docker",
      purl_type: "docker"
    )
    quay = PackageRegistry.create!(
      name: "quay.io",
      url: "https://quay.io",
      ecosystem: "docker",
      purl_type: "docker"
    )
    dependency = create_dependency(
      "known-quay-image",
      ecosystem: "docker",
      package_name: "quay.io/jupyter/base-notebook"
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:resolved)
    package = dependency.reload.package
    assert_equal quay, package.package_registry
    assert_equal "jupyter/base-notebook", package.name
    assert_equal(
      "pkg:docker/jupyter/base-notebook?repository_url=https://quay.io",
      package.purl
    )
  end

  test "records an unknown explicit registry once and retries only when requested" do
    Rails.logger.stubs(:error)
    create_registry(
      name: "npmjs.org",
      url: "https://registry.npmjs.org",
      ecosystem: "npm",
      purl_type: "npm"
    )
    dependency = create_dependency(
      "private-registry",
      ecosystem: "npm",
      package_name: "internal-package",
      purl: "pkg:npm/internal-package?repository_url=https://npm.example.com"
    )

    first = ProjectDependencyResolver.resolve_batch!(limit: 1)
    later_dependency = create_dependency(
      "later-private-registry",
      ecosystem: "npm",
      package_name: "internal-package",
      purl: "pkg:npm/internal-package?repository_url=https://npm.example.com"
    )
    second = ProjectDependencyResolver.resolve_batch!(limit: 1)
    retry_result = ProjectDependencyResolver.resolve_batch!(limit: 1, retry_errors: true)

    assert_equal 1, first.fetch(:failed)
    assert_equal 0, second.fetch(:selected)
    assert_equal 1, retry_result.fetch(:failed)
    assert_match "no package registry for https://npm.example.com",
      dependency.reload.package_resolution_error
    assert dependency.package_resolution_attempted_at.present?
    assert later_dependency.reload.package_resolution_attempted_at.present?
    assert_nil dependency.package_id
  end

  test "skips a known failed coordinate until errors are retried" do
    Rails.logger.stubs(:error)
    create_registry(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem"
    )
    dependency = create_dependency(
      "first-deb",
      ecosystem: "deb",
      package_name: "libexample"
    )

    first = ProjectDependencyResolver.resolve_batch!(limit: 1)
    later_dependency = create_dependency(
      "later-deb",
      ecosystem: "deb",
      package_name: "libexample"
    )
    second = ProjectDependencyResolver.resolve_batch!(limit: 1)
    retry_result = ProjectDependencyResolver.resolve_batch!(
      limit: 1,
      retry_errors: true
    )

    assert_equal 1, first.fetch(:failed)
    assert_equal 0, second.fetch(:selected)
    assert_nil later_dependency.package_resolution_attempted_at
    assert_equal 1, retry_result.fetch(:failed)
    assert dependency.reload.package_resolution_attempted_at.present?
    assert later_dependency.reload.package_resolution_attempted_at.present?
  end

  test "does not mark dependencies when the registry catalog is empty" do
    dependency = create_dependency(
      "no-registries",
      ecosystem: "rubygems",
      package_name: "rails",
      purl: "pkg:gem/rails"
    )

    error = assert_raises(ProjectDependencyResolver::ResolutionError) do
      ProjectDependencyResolver.resolve_batch!(limit: 1)
    end

    assert_equal "package registries must be synced before resolving dependencies",
      error.message
    assert_nil dependency.reload.package_resolution_attempted_at
    assert_nil dependency.package_resolution_error
  end

  test "keeps an unknown Purl type as a registry and name identity" do
    registry = create_registry(
      name: "actions.example.com",
      url: "https://actions.example.com",
      ecosystem: "actions",
      purl_type: "githubactions"
    )
    dependency = create_dependency(
      "actions",
      ecosystem: "actions",
      package_name: "actions/checkout"
    )

    ProjectDependencyResolver.resolve_batch!(limit: 1)

    package = dependency.reload.package
    assert_equal registry, package.package_registry
    assert_equal "actions/checkout", package.name
    assert_nil package.purl
  end

  test "merges a second coordinate for a package already linked to the project" do
    registry = create_registry(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem"
    )
    project = Project.create!(url: "https://github.com/example/duplicate-package")
    package = Package.create!(
      package_registry: registry,
      name: "rails",
      purl: "pkg:gem/rails"
    )
    ProjectDependency.create!(
      project: project,
      package: package,
      ecosystem: "rubygems",
      package_name: "rails",
      purl: package.purl,
      direct: true,
      metadata: { "occurrences" => [{ "filepath" => "Gemfile" }] }
    )
    unresolved = ProjectDependency.create!(
      project: project,
      ecosystem: "gem",
      package_name: "rails",
      purl: package.purl,
      direct: true,
      metadata: { "occurrences" => [{ "filepath" => "gems.rb" }] }
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:resolved)
    assert_not ProjectDependency.exists?(unresolved.id)
    dependency = project.project_dependencies.reload.sole
    assert_equal package, dependency.package
    assert_equal ["Gemfile", "gems.rb"],
      dependency.metadata.fetch("occurrences").pluck("filepath")
  end

  test "limits work by unique identity" do
    create_registry(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem"
    )
    create_dependency(
      "rake",
      ecosystem: "rubygems",
      package_name: "rake",
      purl: "pkg:gem/rake"
    )
    create_dependency(
      "rails",
      ecosystem: "rubygems",
      package_name: "rails",
      purl: "pkg:gem/rails"
    )

    first = ProjectDependencyResolver.resolve_batch!(limit: 1)
    second = ProjectDependencyResolver.resolve_batch!(limit: 1)
    last = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, first.fetch(:selected)
    assert_equal 1, second.fetch(:selected)
    assert_equal 0, last.fetch(:selected)
    assert_equal 2, Package.count
  end

  test "records a malformed Maven coordinate without repeated attempts" do
    Rails.logger.stubs(:error)
    create_registry(
      name: "repo1.maven.org",
      url: "https://repo.maven.apache.org/maven2",
      ecosystem: "maven",
      purl_type: "maven"
    )
    dependency = create_dependency(
      "bad-maven",
      ecosystem: "maven",
      package_name: "missing-group"
    )

    result = ProjectDependencyResolver.resolve_batch!(limit: 1)

    assert_equal 1, result.fetch(:failed)
    assert dependency.reload.package_resolution_attempted_at.present?
    assert dependency.package_resolution_error.present?
    assert_nil dependency.package_id
  end

  test "rejects a batch above the maximum" do
    error = assert_raises(ArgumentError) do
      ProjectDependencyResolver.resolve_batch!(limit: ProjectDependencyResolver::MAX_LIMIT + 1)
    end

    assert_equal "limit must be between 1 and 5000", error.message
  end

  def create_registry(name:, url:, ecosystem:, purl_type:)
    PackageRegistry.create!(
      name: name,
      url: url,
      ecosystem: ecosystem,
      purl_type: purl_type,
      default: true
    )
  end

  def create_dependency(label, ecosystem:, package_name:, purl: nil)
    project = Project.create!(url: "https://github.com/example/#{label}")
    ProjectDependency.create!(
      project: project,
      ecosystem: ecosystem,
      package_name: package_name,
      purl: purl,
      direct: true
    )
  end
end
