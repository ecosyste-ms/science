require "test_helper"

class BriefScanEnqueuerTest < ActiveSupport::TestCase
  setup do
    FetchBriefWorker.jobs.clear
  end

  teardown do
    FetchBriefWorker.jobs.clear
  end

  test "enqueues only eligible JOSS projects" do
    joss = create_project("joss", joss: true)
    create_project("non-joss")
    legacy = create_project("legacy", joss: true, brief: { "version" => "0.12.0" })
    create_project(
      "scanned",
      joss: true,
      brief: { "version" => "0.12.1", "dependencies" => [] }
    )
    create_project(
      "failed",
      joss: true,
      brief: { "error" => "timeout", "attempted_at" => Time.current.iso8601 }
    )
    create_project("unscored", joss: true, science_score: 0)
    create_project("missing-repository", joss: true, repository: nil)

    count = BriefScanEnqueuer.new(limit: 10, cohort: "joss").enqueue

    assert_equal 2, count
    assert_equal [[joss.id], [legacy.id]], FetchBriefWorker.jobs.map { |job| job["args"] }
  end

  test "applies a deterministic non-JOSS shard" do
    projects = 6.times.map { |index| create_project("shard-#{index}") }
    shard = projects.first.id % 2

    BriefScanEnqueuer.new(limit: 10, cohort: "non_joss", shard_count: 2, shard: shard).enqueue

    expected_ids = projects.select { |project| project.id % 2 == shard }.map(&:id)
    assert_equal expected_ids, FetchBriefWorker.jobs.map { |job| job["args"].first }
  end

  test "includes zero-score publishers used directly by scientific projects" do
    publisher = create_project("publisher", science_score: 0)
    create_project("unrelated-zero", science_score: 0)
    registry = PackageRegistry.create!(
      name: "brief-enqueuer.example",
      url: "https://brief-enqueuer.example",
      ecosystem: "brief-enqueuer",
      purl_type: "brief-enqueuer",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      published_by_project: publisher,
      name: "publisher",
      purl: "pkg:brief-enqueuer/publisher"
    )
    dependent = create_project("scientific-dependent", science_score: 20)
    ProjectDependency.create!(
      project: dependent,
      package: package,
      ecosystem: "brief-enqueuer",
      package_name: package.name,
      purl: package.purl,
      direct: true
    )

    count = BriefScanEnqueuer.new(limit: 10).enqueue

    assert_equal 2, count
    assert_equal [publisher.id, dependent.id].sort,
      FetchBriefWorker.jobs.map { |job| job["args"].first }.sort
  end

  test "rejects invalid options" do
    error = assert_raises(ArgumentError) { BriefScanEnqueuer.new(limit: "many") }
    assert_equal "LIMIT must be an integer", error.message

    error = assert_raises(ArgumentError) { BriefScanEnqueuer.new(cohort: "unknown") }
    assert_equal "COHORT must be all, joss, or non_joss", error.message

    error = assert_raises(ArgumentError) { BriefScanEnqueuer.new(shard_count: 2, shard: 2) }
    assert_equal "SHARD must be between zero and SHARD_COUNT - 1", error.message
  end

  def create_project(name, joss: false, brief: nil, science_score: 20, repository: true)
    Project.create!(
      url: "https://github.com/test/brief-enqueuer-#{name}",
      repository: repository ? { "clone_url" => "https://github.com/test/brief-enqueuer-#{name}.git" } : nil,
      science_score: science_score,
      brief: brief,
      joss_metadata: joss ? { "doi" => "10.21105/joss.test" } : nil
    )
  end
end
