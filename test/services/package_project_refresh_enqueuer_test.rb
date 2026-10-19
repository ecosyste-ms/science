require "test_helper"

class PackageProjectRefreshEnqueuerTest < ActiveSupport::TestCase
  setup do
    SyncProjectWorker.jobs.clear
    @now = Time.zone.parse("2026-08-31 12:00:00")
    @registry = PackageRegistry.create!(
      name: "refresh-enqueuer.example",
      url: "https://refresh-enqueuer.example",
      ecosystem: "refresh-enqueuer",
      purl_type: "refresh-enqueuer",
      default: true
    )
  end

  teardown do
    SyncProjectWorker.jobs.clear
  end

  test "enqueues the stalest zero-score publishers with direct scientific use" do
    stalest = create_publisher("stalest", score: 0, synced_at: @now - 20.days)
    stale = create_publisher("stale", score: 0, synced_at: @now - 10.days)
    least_stale = create_publisher("least-stale", score: 0, synced_at: @now - 8.days)
    fresh = create_publisher("fresh", score: 0, synced_at: @now - 1.day)
    positive = create_publisher("positive", score: 5, synced_at: @now - 30.days)

    link_scientific_dependency(stalest, "stalest-1")
    link_scientific_dependency(stale, "stale-1")
    link_scientific_dependency(stale, "stale-2")
    link_scientific_dependency(least_stale, "least-stale-1")
    link_scientific_dependency(fresh, "fresh-1")
    link_scientific_dependency(positive, "positive-1")
    link_non_scientific_dependency(
      create_publisher("non-scientific", score: 0, synced_at: @now - 30.days)
    )

    count = PackageProjectRefreshEnqueuer.new(limit: 2, now: @now).enqueue

    assert_equal 2, count
    assert_equal [[stalest.id], [stale.id]],
      SyncProjectWorker.jobs.map { |job| job["args"] }
  end

  test "rejects limits above the scheduled batch size" do
    error = assert_raises(ArgumentError) do
      PackageProjectRefreshEnqueuer.new(limit: 26)
    end

    assert_equal "LIMIT must be between 1 and 25", error.message
  end

  def create_publisher(name, score:, synced_at:)
    Project.create!(
      url: "https://github.com/test/package-refresh-#{name}",
      science_score: score,
      last_synced_at: synced_at
    )
  end

  def link_scientific_dependency(publisher, name)
    package = create_package(publisher, name)
    dependent = Project.create!(
      url: "https://github.com/test/package-refresh-dependent-#{name}",
      science_score: 20
    )
    create_dependency(dependent, package, direct: true)
  end

  def link_non_scientific_dependency(publisher)
    package = create_package(publisher, "non-scientific")
    dependent = Project.create!(
      url: "https://github.com/test/package-refresh-non-scientific-dependent",
      science_score: 0
    )
    create_dependency(dependent, package, direct: true)
  end

  def create_package(publisher, name)
    Package.create!(
      package_registry: @registry,
      published_by_project: publisher,
      name: name,
      purl: "pkg:refresh-enqueuer/#{name}"
    )
  end

  def create_dependency(project, package, direct:)
    ProjectDependency.create!(
      project: project,
      package: package,
      ecosystem: @registry.ecosystem,
      package_name: package.name,
      purl: package.purl,
      direct: direct
    )
  end
end
