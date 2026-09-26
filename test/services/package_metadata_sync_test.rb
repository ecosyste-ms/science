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

  test "lowercases NuGet Purls for metadata lookup" do
    registry = PackageRegistry.create!(
      name: "nuget.org",
      url: "https://nuget.org",
      ecosystem: "nuget",
      purl_type: "nuget",
      default: true
    )
    package = create_package(
      package_registry: registry,
      name: "System.Runtime.Serialization.Formatters",
      purl: "pkg:nuget/System.Runtime.Serialization.Formatters"
    )
    client = mock
    client.expects(:package_lookup)
      .with(purl: "pkg:nuget/system.runtime.serialization.formatters")
      .returns([{
        "id" => 8_910_484,
        "name" => package.name.downcase,
        "purl" => "pkg:nuget/system.runtime.serialization.formatters",
        "registry" => { "name" => registry.name },
      }])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:matched)
    package.reload
    assert_equal 8_910_484, package.ecosystems_id
    assert_equal "pkg:nuget/system.runtime.serialization.formatters", package.purl
  end

  test "lowercases NuGet names for registry-scoped metadata lookup" do
    registry = PackageRegistry.create!(
      name: "nuget.org",
      url: "https://nuget.org",
      ecosystem: "nuget",
      purl_type: "nuget",
      default: true
    )
    package = create_package(
      package_registry: registry,
      name: "Microsoft.Extensions.AI.OpenAI"
    )
    client = mock
    client.expects(:package_lookup)
      .with(
        registry_name: registry.name,
        ecosystem: registry.ecosystem,
        name: "microsoft.extensions.ai.openai"
      )
      .returns([{
        "id" => 8_910_485,
        "name" => package.name.downcase,
        "purl" => "pkg:nuget/microsoft.extensions.ai.openai",
        "registry" => { "name" => registry.name },
      }])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 1)

    assert_equal 1, result.fetch(:matched)
    assert_equal 8_910_485, package.reload.ecosystems_id
  end

  test "stops missing packages after one lookup" do
    package = create_package(name: "internal-gem", purl: "pkg:gem/internal-gem")
    client = mock
    client.expects(:package_lookup).once.returns([])

    first = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    assert_equal 1, first.fetch(:unavailable)
    assert_equal "unavailable", package.reload.ecosystems_sync_status
    assert_equal 1, package.ecosystems_miss_count
    assert_nil package.ecosystems_retry_at

    second = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    assert_equal 0, second.fetch(:selected)
  end

  test "retries missing packages only when stopped retries are requested" do
    package = create_package(
      name: "internal-gem",
      purl: "pkg:gem/internal-gem",
      ecosystems_sync_status: "missing",
      ecosystems_checked_at: 1.day.ago,
      ecosystems_retry_at: 1.minute.ago
    )
    client = mock
    client.expects(:package_lookup).once.returns([])

    automatic = PackageMetadataSync.sync_batch!(client: client, limit: 1)
    explicit = PackageMetadataSync.sync_batch!(
      client: client,
      limit: 1,
      retry_stopped: true
    )

    assert_equal 0, automatic.fetch(:selected)
    assert_equal 1, explicit.fetch(:unavailable)
    assert_equal "unavailable", package.reload.ecosystems_sync_status
    assert_equal 1, package.ecosystems_miss_count
    assert_nil package.ecosystems_retry_at
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

  test "stops a local identity conflict and continues the batch" do
    existing = create_package(
      name: "canonical-gem",
      purl: "pkg:gem/canonical-gem",
      ecosystems_sync_status: "matched",
      ecosystems_checked_at: Time.current
    )
    conflict = create_package(name: "conflicting-gem")
    valid = create_package(name: "valid-gem", purl: "pkg:gem/valid-gem")
    client = mock
    client.expects(:package_lookup)
      .with(
        registry_name: @registry.name,
        ecosystem: @registry.ecosystem,
        name: conflict.name
      )
      .returns([package_record(
        id: 124,
        name: conflict.name,
        purl: existing.purl
      )])
    client.expects(:package_lookup)
      .with(purl: valid.purl)
      .returns([package_record(id: 125, name: valid.name, purl: valid.purl)])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 2)

    assert_equal 1, result.fetch(:ambiguous)
    assert_equal 1, result.fetch(:matched)
    assert_equal "ambiguous", conflict.reload.ecosystems_sync_status
    assert_includes conflict.ecosystems_error, existing.id.to_s
    assert_equal "matched", valid.reload.ecosystems_sync_status
  end

  test "continues after matched metadata fails package validation" do
    Rails.logger.stubs(:error)
    invalid = create_package(name: "invalid-gem", purl: "pkg:gem/invalid-gem")
    valid = create_package(name: "valid-gem", purl: "pkg:gem/valid-gem")
    client = mock
    client.expects(:package_lookup)
      .with(purl: invalid.purl)
      .returns([package_record(
        id: 124,
        name: invalid.name,
        purl: "pkg:npm/invalid-gem"
      )])
    client.expects(:package_lookup)
      .with(purl: valid.purl)
      .returns([package_record(id: 125, name: valid.name, purl: valid.purl)])

    result = PackageMetadataSync.sync_batch!(client: client, limit: 2)

    assert_equal 1, result.fetch(:transient_error)
    assert_equal 1, result.fetch(:matched)
    invalid.reload
    assert_equal "pkg:gem/invalid-gem", invalid.purl
    assert_equal "transient_error", invalid.ecosystems_sync_status
    assert_equal "matched", valid.reload.ecosystems_sync_status
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
