require "test_helper"

class PackageMetadataSyncTest < ActiveSupport::TestCase
  setup do
    @registry = PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )
  end

  test "stores upstream metadata and clears a stale project match" do
    project = Project.create!(url: "https://github.com/example/old")
    package = create_package(
      name: "rails",
      purl: "pkg:gem/rails",
      repository_url: project.url,
      published_by_project: project,
      repository_checked_at: Time.current
    )
    client = mock
    client.expects(:package_lookup)
      .with(purl: "pkg:gem/rails")
      .returns([package_record(
        id: 123,
        name: "rails",
        repository_url: "https://github.com/rails/rails"
      )])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:matched)
    package.reload
    assert_equal 123, package.ecosystems_id
    assert_equal "matched", package.ecosystems_sync_status
    assert_equal "https://github.com/rails/rails", package.repository_url
    assert_equal "pkg:gem/rails", package.purl
    assert_equal 123, package.metadata.fetch("id")
    assert_equal 200, package.general_dependent_repositories_count
    assert_in_delta 0.4, package.dependent_repositories_top_percentage
    assert_in_delta 1.5, package.average_top_percentage
    assert_not_nil package.ranking_metadata_normalized_at
    assert_equal Time.zone.parse("2026-08-30T12:00:00Z"),
      package.ecosystems_updated_at
    assert_nil package.published_by_project_id
    assert_nil package.repository_checked_at
    assert_nil package.ecosystems_retry_at
  end

  test "uses a registry-scoped lookup when the package has no Purl" do
    package = create_package(name: "actions/checkout")
    client = mock
    client.expects(:package_lookup)
      .with(
        registry_name: "rubygems.org",
        ecosystem: "rubygems",
        name: "actions/checkout"
      )
      .returns([package_record(id: 124, name: "actions/checkout", purl: nil)])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:matched)
    assert_equal 124, package.reload.ecosystems_id
  end

  test "spaces missing retries and stops after three misses" do
    package = create_package(name: "internal-gem", purl: "pkg:gem/internal-gem")
    client = mock
    client.expects(:package_lookup).times(3).returns([])

    first = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    assert_equal 1, first.fetch(:missing)
    assert_in_delta 1.day.from_now, package.reload.ecosystems_retry_at, 2.seconds

    package.update_column(:ecosystems_retry_at, 1.minute.ago)
    second = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    assert_equal 1, second.fetch(:missing)
    assert_in_delta 7.days.from_now, package.reload.ecosystems_retry_at, 2.seconds

    package.update_column(:ecosystems_retry_at, 1.minute.ago)
    third = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    assert_equal 1, third.fetch(:unavailable)
    assert_equal "unavailable", package.reload.ecosystems_sync_status
    assert_equal 3, package.ecosystems_miss_count
    assert_nil package.ecosystems_retry_at

    fourth = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    assert_equal 0, fourth.fetch(:selected)
  end

  test "records an ambiguous result without retrying it automatically" do
    package = create_package(name: "rails", purl: "pkg:gem/rails")
    client = mock
    client.expects(:package_lookup).once.returns([
      package_record(id: 1, name: "rails"),
      package_record(id: 2, name: "rails"),
    ])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:ambiguous)
    package.reload
    assert_equal "ambiguous", package.ecosystems_sync_status
    assert_equal "lookup returned 2 packages", package.ecosystems_error
    assert_nil package.ecosystems_retry_at
  end

  test "records a transient request error for a later retry" do
    Rails.logger.stubs(:error)
    package = create_package(name: "rails", purl: "pkg:gem/rails")
    client = mock
    client.expects(:package_lookup)
      .raises(PackagesApiClient::RequestError, "HTTP 503")

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:transient_error)
    package.reload
    assert_equal "transient_error", package.ecosystems_sync_status
    assert_equal 1, package.ecosystems_error_count
    assert_includes package.ecosystems_error, "HTTP 503"
    assert_in_delta 1.hour.from_now, package.ecosystems_retry_at, 2.seconds
  end

  test "refreshes matched packages after thirty days" do
    package = create_package(
      name: "rails",
      purl: "pkg:gem/rails",
      ecosystems_sync_status: "matched",
      ecosystems_checked_at: 31.days.ago
    )
    client = mock
    client.expects(:package_lookup).returns([
      package_record(id: 123, name: "rails")
    ])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:matched)
    assert package.reload.ecosystems_checked_at > 1.minute.ago
  end

  def create_package(attributes)
    Package.create!({ package_registry: @registry }.merge(attributes))
  end

  def package_record(
    id:,
    name:,
    purl: "pkg:gem/rails",
    repository_url: "https://github.com/rails/rails"
  )
    {
      "id" => id,
      "name" => name,
      "namespace" => nil,
      "purl" => purl,
      "repository_url" => repository_url,
      "updated_at" => "2026-08-30T12:00:00Z",
      "dependent_repos_count" => 200,
      "rankings" => {
        "dependent_repos_count" => 0.4,
        "average" => 1.5,
      },
      "registry" => { "name" => @registry.name },
    }
  end
end
