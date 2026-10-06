require "test_helper"
require_relative "../support/swhid_pipeline"

class BriefScanEnqueuerTest < ActiveSupport::TestCase
  include SwhidPipeline
  setup do
    RepositoryScanWorker.jobs.clear
  end

  teardown do
    RepositoryScanWorker.jobs.clear
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
    assert_equal [[joss.id], [legacy.id]], RepositoryScanWorker.jobs.map { |job| job["args"] }
  end

  test "applies a deterministic non-JOSS shard" do
    projects = 6.times.map { |index| create_project("shard-#{index}") }
    shard = projects.first.id % 2

    BriefScanEnqueuer.new(limit: 10, cohort: "non_joss", shard_count: 2, shard: shard).enqueue

    expected_ids = projects.select { |project| project.id % 2 == shard }.map(&:id)
    assert_equal expected_ids, RepositoryScanWorker.jobs.map { |job| job["args"].first }
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
      RepositoryScanWorker.jobs.map { |job| job["args"].first }.sort
  end

  test "rejects invalid options" do
    error = assert_raises(ArgumentError) { BriefScanEnqueuer.new(limit: "many") }
    assert_equal "LIMIT must be an integer", error.message

    error = assert_raises(ArgumentError) { BriefScanEnqueuer.new(cohort: "unknown") }
    assert_equal "COHORT must be all, joss, or non_joss", error.message

    error = assert_raises(ArgumentError) { BriefScanEnqueuer.new(shard_count: 2, shard: 2) }
    assert_equal "SHARD must be between zero and SHARD_COUNT - 1", error.message
  end

  test "enqueues retrieved identifier matches regardless of score or case" do
    projects = %w[ASCL BioTools swMATH RRID Wikidata DOI].map do |source|
      project = create_project(source, science_score: 0)
      record = ExternalSoftwareRecord.create!(source: source, identifier: source, status: "error", retrieved_at: Time.current, next_refresh_at: Time.current)
      record.update_column(:status, "Error")
      ProjectExternalSoftwareRecord.create!(project: project, external_software_record: record, relationship: "repository", match_status: "Matched")
      project
    end

    assert_equal 6, BriefScanEnqueuer.new(limit: 10).enqueue
    assert_equal projects.map(&:id).sort, RepositoryScanWorker.jobs.map { |job| job['args'].first }.sort
  end

  test "registry scan selection excludes unconfirmed records and hidden or completed projects" do
    [
      ["ambiguous", "ascl", "ambiguous", "ok", Time.current, nil],
      ["missing", "biotools", "matched", "missing", Time.current, nil],
      ["unretrieved", "rrid", "matched", "error", nil, nil],
      ["unmatched-doi", "doi", "unmatched", "ok", Time.current, nil],
      ["scanned", "ascl", "matched", "ok", Time.current, { "dependencies" => [] }],
      ["failed", "swmath", "matched", "ok", Time.current, { "error" => "timeout" }],
      ["hidden", "ascl", "matched", "ok", Time.current, nil],
    ].each do |name, source, match_status, status, retrieved_at, brief|
      project = create_project(name, science_score: 0, brief: brief)
      if name == "hidden"
        host = Host.create!(name: "GitHub")
        owner = Owner.create!(host: host, login: "hidden-registry")
        project.update!(owner_record: owner)
        owner.update!(hidden: true)
      end
      record = ExternalSoftwareRecord.create!(source: source, identifier: name, status: status, retrieved_at: retrieved_at, next_refresh_at: Time.current)
      ProjectExternalSoftwareRecord.create!(project: project, external_software_record: record, relationship: "repository", match_status: match_status)
    end

    assert_equal 0, BriefScanEnqueuer.new(limit: 10).enqueue
    assert_empty RepositoryScanWorker.jobs
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
