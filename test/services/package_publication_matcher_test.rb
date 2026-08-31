require "test_helper"

class PackagePublicationMatcherTest < ActiveSupport::TestCase
  setup do
    SyncProjectWorker.jobs.clear
    @registry = PackageRegistry.create!(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi",
      default: true
    )
  end

  teardown do
    SyncProjectWorker.jobs.clear
  end

  test "matches a normalized package repository to a project" do
    project = Project.create!(url: "https://github.com/numpy/numpy")
    package = create_package(
      "numpy",
      repository_url: "git@github.com:NumPy/numpy.git"
    )

    result = PackagePublicationMatcher.match_batch!(limit: 1)

    assert_equal 1, result.fetch(:matched)
    assert_equal project, package.reload.published_by_project
    assert package.repository_checked_at.present?
    assert_nil package.repository_match_error
  end

  test "matches a previous repository name" do
    project = Project.create!(
      url: "https://github.com/science-org/current-name",
      repository: { "previous_names" => ["science-org/old-name"] }
    )
    package = create_package(
      "renamed-package",
      repository_url: "https://github.com/science-org/old-name"
    )
    ProjectRepositoryAliasIndexer.new(project).sync!

    result = PackagePublicationMatcher.match_batch!(limit: 1)

    assert_equal 1, result.fetch(:matched)
    assert_equal project, package.reload.published_by_project
  end

  test "records an ambiguous repository identity" do
    Project.create!(url: "https://github.com/science-org/shared-name")
    renamed = Project.create!(
      url: "https://github.com/science-org/current-name",
      repository: { "previous_names" => ["science-org/shared-name"] }
    )
    package = create_package(
      "ambiguous-package",
      repository_url: "https://github.com/science-org/shared-name"
    )
    ProjectRepositoryAliasIndexer.new(renamed).sync!

    result = PackagePublicationMatcher.match_batch!(limit: 1)

    assert_equal 1, result.fetch(:ambiguous)
    package.reload
    assert_nil package.published_by_project_id
    assert_equal "multiple projects match repository URL",
      package.repository_match_error
  end

  test "creates and enqueues a project for an unmatched package repository" do
    package = create_package(
      "missing-package",
      repository_url: "https://github.com/science-org/missing"
    )

    result = PackagePublicationMatcher.match_batch!(limit: 1)

    project = Project.find_by!(
      url: "https://github.com/science-org/missing"
    )

    assert_equal 1, result.fetch(:discovered)
    assert_equal project, package.reload.published_by_project
    assert package.repository_checked_at.present?
    assert_nil package.repository_match_error
    assert_equal [[project.id]], SyncProjectWorker.jobs.map { |job| job["args"] }

    second = PackagePublicationMatcher.match_batch!(limit: 1)

    assert_equal 0, second.fetch(:selected)
  end

  test "links packages that share an unmatched repository" do
    first = create_package(
      "first-package",
      repository_url: "https://github.com/science-org/shared-package"
    )
    second = create_package(
      "second-package",
      repository_url: "https://github.com/science-org/shared-package"
    )

    result = PackagePublicationMatcher.match_batch!(limit: 2)

    project = Project.find_by!(
      url: "https://github.com/science-org/shared-package"
    )

    assert_equal 1, result.fetch(:discovered)
    assert_equal 1, result.fetch(:matched)
    assert_equal project, first.reload.published_by_project
    assert_equal project, second.reload.published_by_project
    assert_equal [[project.id]], SyncProjectWorker.jobs.map { |job| job["args"] }
  end

  test "limits each project matching batch" do
    create_package(
      "first",
      repository_url: "https://github.com/science-org/first"
    )
    create_package(
      "second",
      repository_url: "https://github.com/science-org/second"
    )

    result = PackagePublicationMatcher.match_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, Package.where.not(repository_checked_at: nil).count
  end

  def create_package(name, repository_url:)
    Package.create!(
      package_registry: @registry,
      name: name,
      purl: "pkg:pypi/#{name}",
      repository_url: repository_url,
      ecosystems_sync_status: "matched",
      ecosystems_checked_at: Time.current
    )
  end
end
