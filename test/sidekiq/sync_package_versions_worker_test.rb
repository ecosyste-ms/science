require "test_helper"

class SyncPackageVersionsWorkerTest < ActiveSupport::TestCase
  setup do
    SyncPackageVersionsWorker.jobs.clear
    @project = Project.create!(url: "https://github.com/science/tool", science_score: 50)
    registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org",
      ecosystem: "pypi", purl_type: "pypi")
    @package = Package.create!(package_registry: registry, name: "tool", ecosystems_id: 42,
      published_by_project: @project, metadata: {
        "versions_url" => "https://packages.ecosyste.ms/api/v1/registries/pypi.org/packages/tool/versions"
      })
  end

  teardown { SyncPackageVersionsWorker.jobs.clear }

  test "joined console lookup queues and imports the selected package" do
    @package.update!(name: "Tool")
    @package.package_registry.update!(ecosystem: "PyPI")
    respond_with([version])

    package = Package.version_importable.joins(:package_registry)
      .where(published_by_project_id: @project.id)
      .where("LOWER(packages.name) = ? AND LOWER(package_registries.ecosystem) = ?", "tool", "pypi")
      .first!
    package.sync_versions

    assert_equal @package.id, package.id
    assert_equal [[@package.id]], SyncPackageVersionsWorker.jobs.map { |job| job["args"] }
    SyncPackageVersionsWorker.drain
    assert_equal "1.0", package.package_versions.sole.number
    assert package.reload.version_sync_state["completed_at"]
  end

  test "console entrypoint queues a catalog import with source metadata and a name-based release match" do
    release = @project.releases.create!(tag_name: "v1.0", tag_sha: "a" * 40)
    respond_with([version])

    @package.sync_versions
    assert_equal [[@package.id]], SyncPackageVersionsWorker.jobs.map { |job| job["args"] }
    assert_not_requested :get, /packages.ecosyste.ms/
    SyncPackageVersionsWorker.drain

    imported = @package.package_versions.sole
    assert_equal 101, imported.ecosystems_id
    assert_equal "1.0", imported.number
    assert_equal "MIT", imported.licenses
    assert_equal "sha256-abc", imported.integrity
    assert_nil imported.status
    assert_nil imported.immutable
    assert_equal({ "gitHead" => "a" * 40 }, imported.metadata)
    assert_equal Time.utc(2026, 1, 1), imported.published_at
    assert_equal Time.utc(2026, 1, 2), imported.ecosystems_created_at
    assert_equal Time.utc(2026, 1, 3), imported.ecosystems_updated_at
    assert_equal release.id, imported.release_id
    assert_equal "packages_related_tag", imported.release_match_method
    assert_equal version["related_tag"], imported.related_tag
    assert_not imported.attributes.key?("dependencies")
    assert @package.reload.version_sync_state["completed_at"]
    assert @package.version_sync_state["synced_through"]
  end

  test "imports at most one page per job and keeps the initial scan time across continuations" do
    records = 100.times.map { |i| version.merge("id" => i + 1, "number" => "0.#{i}", "related_tag" => nil) }
    respond_with(records, headers: { "Link" => '<https://packages.ecosyste.ms/versions?page=2>; rel="next"' })
    respond_with([version], page: 2)

    perform
    state = @package.reload.version_sync_state
    assert_equal 100, @package.package_versions.count
    assert_equal 2, state["page"]
    assert_nil state["completed_at"]
    assert_equal 1, SyncPackageVersionsWorker.jobs.size
    scan_started_at = state["scan_started_at"]

    travel 1.minute do
      SyncPackageVersionsWorker.drain
    end

    assert_equal 101, @package.package_versions.count
    assert_equal 1, @package.reload.version_sync_state["page"]
    assert_equal scan_started_at, @package.version_sync_state["synced_through"]
  end

  test "incremental refresh overlaps the previous scan and upserts numbers case insensitively" do
    respond_with([version.merge("number" => "1.0RC1", "immutable" => nil)])
    perform
    imported = @package.package_versions.sole
    checkpoint = @package.reload.version_sync_state.fetch("synced_through")
    since = (Time.iso8601(checkpoint) - 5.minutes).iso8601
    respond_with([version.merge("number" => "1.0rc1", "immutable" => true,
      "status" => "yanked", "updated_at" => "2026-09-21T12:00:00Z")], updated_after: since)

    travel 2.days do
      @package.sync_versions
      SyncPackageVersionsWorker.drain
    end

    assert_equal 1, @package.package_versions.count
    assert_equal "1.0rc1", imported.reload.number
    assert_equal true, imported.immutable
    assert_equal "yanked", imported.status
    assert @package.version_sync_state["synced_through"]
  end

  test "unchanged versions are not rewritten and partial scans preserve missing versions" do
    respond_with([version, version.merge("id" => 102, "number" => "2.0")])
    perform
    imported = @package.package_versions.find_by!(ecosystems_id: 101)
    timestamps = imported.attributes.slice("updated_at", "fetched_at")
    since = (Time.iso8601(@package.reload.version_sync_state.fetch("synced_through")) - 5.minutes).iso8601
    respond_with([version], updated_after: since)

    travel 2.days do
      perform
    end

    assert_equal 2, @package.package_versions.count
    assert_equal timestamps, imported.reload.attributes.slice("updated_at", "fetched_at")
  end

  test "a throttled second page retains its cursor and retries after the supplied delay" do
    respond_with([version], headers: { "Link" => '<https://packages.ecosyste.ms/versions?page=2>; rel="next"' })
    perform
    SyncPackageVersionsWorker.jobs.clear
    respond_with([], page: 2, status: 429, headers: { "Retry-After" => "7200" })

    perform

    state = @package.reload.version_sync_state
    assert_equal 2, state["page"]
    assert_includes state["error"], "429"
    assert_requested :get, @package.metadata.fetch("versions_url"), times: 1,
      query: { per_page: "100", page: "2", sort: "created_at", order: "asc" }
    assert_nil state["synced_through"]
    assert_in_delta 2.hours.from_now.to_f, SyncPackageVersionsWorker.jobs.sole["at"], 3

    respond_with([version.merge("id" => 102, "number" => "2.0")], page: 2)
    travel 2.hours + 5.seconds do
      perform
    end
    assert_equal 2, @package.package_versions.count
    assert_nil @package.reload.version_sync_state["error"]
    assert @package.version_sync_state["completed_at"]
  end

  test "malformed records roll back the page and do not advance the cursor" do
    respond_with([version, version.except("number")])

    perform

    assert_empty @package.package_versions
    assert_equal 1, @package.reload.version_sync_state["page"]
    assert_includes @package.version_sync_state["error"], "number"
    assert_nil @package.version_sync_state["completed_at"]
  end

  test "identity conflicts preserve stored versions and continue other records without advancing the watermark" do
    respond_with([version])
    perform
    original = @package.package_versions.sole
    checkpoint = @package.reload.version_sync_state.fetch("synced_through")
    since = (Time.iso8601(checkpoint) - 5.minutes).iso8601
    respond_with([
      version.merge("id" => 999, "immutable" => true),
      version.merge("number" => "renamed", "immutable" => true),
      version.merge("id" => 102, "number" => "2.0")
    ], updated_after: since)

    travel 2.days do
      perform
    end

    assert_equal 2, @package.package_versions.count
    assert_nil original.reload.immutable
    assert_equal "1.0", original.number
    assert_equal 2, @package.reload.version_sync_state["conflicts"]
    assert_equal checkpoint, @package.version_sync_state["synced_through"]
  end

  test "ambiguous or differently cased tag hints stay unlinked" do
    2.times { @project.releases.create!(tag_name: "v1.0") }
    @project.releases.create!(tag_name: "V2.0")
    respond_with([version, version.merge("id" => 102, "number" => "2.0", "related_tag" => { "name" => "v2.0" })])

    perform

    assert_equal 2, @package.package_versions.count
    assert_equal [nil], @package.package_versions.distinct.pluck(:release_id)
    assert_equal [nil], @package.package_versions.distinct.pluck(:release_match_method)
    assert @package.package_versions.first.related_tag.present?
  end

  test "matches are scoped to the publisher and cleared when it changes" do
    release = @project.releases.create!(tag_name: "v1.0")
    other = Project.create!(url: "https://github.com/science/other", science_score: 50)
    other_release = other.releases.create!(tag_name: "v1.0")
    respond_with([version])
    perform
    imported = @package.package_versions.sole
    assert_equal release.id, imported.release_id

    @package.reload.update!(published_by_project: other)

    assert_nil imported.reload.release_id
    assert_nil imported.release_match_method
    assert_empty @package.version_sync_state
    @package.sync_versions
    SyncPackageVersionsWorker.drain
    assert_equal other_release.id, imported.reload.release_id
  end

  test "active leases prevent overlapping work and stale work cannot commit after a new claim" do
    respond_with([version]) do
      @package.update_columns(version_sync_state: @package.reload.version_sync_state.merge("token" => "new-worker"))
    end

    perform
    assert_empty @package.package_versions
    assert_equal "new-worker", @package.reload.version_sync_state["token"]
    reset_executed_requests!

    perform
    assert_not_requested :get, /packages.ecosyste.ms/
    respond_with([version])
    travel 6.minutes do
      perform
    end
    assert_equal 1, @package.package_versions.count
  end

  test "hidden publishers and packages outside scientific projects are not imported" do
    @project.update!(science_score: 0)
    @package.sync_versions
    perform
    assert_empty SyncPackageVersionsWorker.jobs
    assert_empty @package.package_versions

    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "science", hidden: true)
    @project.update_columns(science_score: 50, owner_id: owner.id)
    @package.sync_versions
    perform
    assert_not_requested :get, /packages.ecosyste.ms/
    assert_empty SyncPackageVersionsWorker.jobs
  end

  test "an unexpected versions URL never receives a request" do
    @package.update!(metadata: { "versions_url" => "https://example.org/versions" })

    perform

    assert_includes @package.reload.version_sync_state["error"], "invalid Packages versions URL"
    assert_not_requested :get, /example.org/
  end

  test "imports encoded scoped package names from the advertised URL" do
    @package.update!(metadata: {
      "versions_url" => "https://packages.ecosyste.ms/api/v1/registries/npmjs.org/packages/@scope%2Ftool/versions"
    })
    respond_with([version])

    perform

    assert_equal 1, @package.package_versions.count
    assert_nil @package.reload.version_sync_state["error"]
  end

  test "database constraints reject duplicate numbers regardless of case and duplicate source IDs" do
    respond_with([version.merge("number" => "1.0RC1")])
    perform

    [{ ecosystems_id: 102, number: "1.0rc1" }, { ecosystems_id: 101, number: "2.0" }].each do |attributes|
      assert_raises ActiveRecord::RecordNotUnique do
        PackageVersion.transaction(requires_new: true) do
          @package.package_versions.create!(attributes.merge(fetched_at: Time.current))
        end
      end
    end
    assert_equal 1, @package.package_versions.count
  end

  test "invalid pagination and non-list responses leave existing data and progress unchanged" do
    [
      [[version], { "Link" => '<https://packages.ecosyste.ms/versions?page=1>; rel="next"' }],
      [{ "message" => "not a version list" }, {}]
    ].each do |records, headers|
      @package.update_columns(version_sync_state: {})
      respond_with(records, headers: headers)
      perform
      assert_empty @package.package_versions
      assert @package.reload.version_sync_state["error"]
      assert_equal 1, @package.version_sync_state["page"]
    end
  end

  def version
    {
      "id" => 101, "number" => "1.0", "published_at" => "2026-01-01T00:00:00Z",
      "created_at" => "2026-01-02T00:00:00Z", "updated_at" => "2026-01-03T00:00:00Z",
      "licenses" => "MIT", "integrity" => "sha256-abc", "status" => nil, "immutable" => nil,
      "metadata" => { "gitHead" => "a" * 40 }, "related_tag" => { "name" => "v1.0", "sha" => "a" * 40 },
      "purl" => "pkg:pypi/tool@1.0", "download_url" => "https://example.org/tool-1.0.tar.gz",
      "registry_url" => "https://pypi.org/project/tool/1.0/", "documentation_url" => nil,
      "dependencies" => [{ "package_name" => "numpy", "requirements" => ">=1" }]
    }
  end

  def respond_with(records, page: 1, status: 200, headers: {}, updated_after: nil, &block)
    stub_request(:get, @package.metadata.fetch("versions_url"))
      .with(query: { per_page: "100", page: page.to_s, sort: "created_at", order: "asc",
        updated_after: updated_after }.compact)
      .to_return do
        block&.call
        { status: status, body: records.to_json, headers: headers }
      end
  end

  def perform
    SyncPackageVersionsWorker.new.perform(@package.id)
  end
end
