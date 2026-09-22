require "test_helper"
require "rake"
require_relative "../support/swhid_pipeline"

class SwhidsRakeTest < ActiveSupport::TestCase
  include SwhidPipeline
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("swhids:contributions")
    Rake::Task["swhids:contributions"].reenable
    Rake::Task["swhids:coverage"].reenable
    Rake::Task["swhids:check_origins"].reenable
  end

  test "contributions counts distinct identifiers from completed worker requests" do
    revision = "swh:1:rev:#{'a' * 40}"
    directory = "swh:1:dir:#{'b' * 40}"
    known = stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(body: { revision => { known: false }, directory => { known: false } }.to_json)
      .then.to_return(body: { revision => { known: true }, directory => { known: true } }.to_json)
      .then.to_return(body: { revision => { known: false }, directory => { known: false } }.to_json)
      .then.to_return(body: { revision => { known: true }, directory => { known: true } }.to_json)

    2.times do |index|
      origin = "https://github.com/example/contribution-#{index}"
      project = Project.create!(url: origin, science_score: 42, repository: { "clone_url" => origin }, swhids: {
        "status" => "success", "origin" => origin,
        "revision" => { "status" => "success", "swhid" => revision },
        "directory" => { "status" => "success", "swhid" => directory }
      })
      stub_request(:post, SwhidArchiver::ENDPOINT).with(query: { "visit_type" => "git", "origin_url" => origin })
        .to_return do
          { status: 200, body: { id: index + 1, origin_url: origin, visit_type: "git", save_request_date: Time.current.iso8601,
            save_request_status: "accepted", save_task_status: "succeeded" }.to_json }
        end
      perform_fetch(project.id)
    end

    output, = capture_io { Rake::Task["swhids:contributions"].invoke }

    assert_includes output, "Eligible science projects: 2\n"
    assert_includes output, "Projects with new archival requests: 2/2 (100.0%)\n"
    assert_includes output, "Projects with successful imports: 2/2 (100.0%)\n"
    assert_includes output, "SWHIDs archived after our request: 2\nRevisions: 1\nDirectories: 1\n"
    assert_requested known, times: 4
  end

  test "contributions reports zero without submitting requests" do
    output, = capture_io { Rake::Task["swhids:contributions"].invoke }

    assert_includes output, "Eligible science projects: 0\n"
    assert_includes output, "Projects with new archival requests: 0/0 (n/a)\n"
    assert_includes output, "Projects with successful imports: 0/0 (n/a)\n"
    assert_includes output, "SWHIDs archived after our request: 0\nRevisions: 0\nDirectories: 0\n"
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "contributions separates eligible project coverage from all recorded identifiers" do
    coverage_project("versions", "archived", "missing_versions", imported: true)
    coverage_project("repository", "not_found", "missing_repository")
    historical = coverage_project("historical", "archived", "missing_versions", imported: true)
    historical.update!(swhids: historical.swhids.deep_merge("archival" => {
      "repository_before_request" => { "basis" => "visit_history" }
    }))
    coverage_project("unknown", "unknown", nil)
    coverage_project("unchecked", nil, nil, request_id: nil)
    reused = coverage_project("reused", "archived", "missing_versions", imported: true)
    reused.update!(swhids: reused.swhids.deep_merge("archival" => { "attribution_eligible" => false }))
    excluded = coverage_project("unscientific-contribution", "archived", "missing_versions", imported: true)
    excluded.update!(science_score: 0, swhids: excluded.swhids.deep_merge("archival" => {
      "status" => "completed", "confirmed_swhids" => ["swh:1:rev:#{'c' * 40}"]
    }))

    output, = capture_io { Rake::Task["swhids:contributions"].invoke }

    assert_equal <<~REPORT, output
      Eligible science projects: 6
      Projects with new archival requests: 4/6 (66.7%)
      Projects with successful imports: 2/6 (33.3%)

      Repository coverage among eligible projects:
        Archived snapshot found: 3
        No snapshot found at checked URLs: 1
        Unknown: 1
        Unchecked: 1

      Submitted projects by prior repository coverage:
        Missing versions of previously archived repositories: 2
        No repository snapshot found before submission: 1
        Prior repository coverage unknown: 1

      Imported projects by prior repository coverage:
        Missing versions of previously archived repositories: 2
        No repository snapshot found before submission: 0
        Prior repository coverage unknown: 0

      Submission evidence:
        Observed before submission: 2
        Inferred from historical visit dates: 1
        Unknown: 1

      Confirmed contributions across all recorded projects:
      SWHIDs archived after our request: 1
      Revisions: 1
      Directories: 0
    REPORT
    assert_not_requested :any, /archive\.softwareheritage\.org/
    assert_empty RepositoryScanWorker.jobs
    assert_empty CheckSwhidBatchWorker.jobs
  end

  test "coverage report separates repository coverage and submission categories within eligible projects" do
    coverage_project("versions", "archived", "missing_versions", imported: true)
    coverage_project("repository", "not_found", "missing_repository")
    coverage_project("unknown", "unknown", nil, imported: true)
    coverage_project("unchecked", nil, nil, request_id: nil)
    reused = coverage_project("reused", "archived", "missing_versions", imported: true)
    reused.update!(swhids: reused.swhids.deep_merge("archival" => { "attribution_eligible" => false }))
    coverage_project("limited", "not_found", "missing_repository", request_id: nil)
    excluded = coverage_project("unscientific", "archived", "missing_versions", imported: true)
    excluded.update!(science_score: 0)
    no_repository = coverage_project("no-repository", "archived", "missing_versions")
    no_repository.update!(repository: nil)

    output, = capture_io { Rake::Task["swhids:coverage"].invoke }
    result = JSON.parse(output)

    assert_equal 6, result["eligible_projects"]
    assert_equal({ "archived" => 2, "not_found" => 2, "unknown" => 1, "unchecked" => 1 }, result["repository_coverage"])
    assert_equal({ "missing_versions" => 1, "missing_repository" => 1, "unknown" => 1 }, result["submitted_projects"])
    assert_equal({ "missing_versions" => 1, "missing_repository" => 0, "unknown" => 1 }, result["imported_projects"])
    assert_equal({ "pre_submission" => 2, "unknown" => 1 }, result["submission_evidence"])
    assert_not_requested :get, /archive\.softwareheritage\.org/
  end

  test "origin backfill queues a bounded page of existing requests and can resume by ID" do
    first = coverage_project("first", nil, nil)
    second = coverage_project("second", nil, nil)
    coverage_project("no-request", nil, nil, request_id: nil)
    previous = ENV.to_h.slice("LIMIT", "AFTER_ID", "REQUESTS_ONLY")
    ENV["LIMIT"] = "1"
    ENV["AFTER_ID"] = "0"
    ENV["REQUESTS_ONLY"] = "true"

    output, = capture_io { Rake::Task["swhids:check_origins"].invoke }

    assert_equal({ "selected" => 1, "queued" => 1, "last_project_id" => first.id }, JSON.parse(output))
    assert_equal [[first.id]], CheckSwhidOriginWorker.jobs.map { |job| job["args"] }
    CheckSwhidOriginWorker.perform_one
    assert_equal "not_found", first.reload.swhids.dig("origin_archive", "status")
    assert_nil first.swhids.dig("archival", "repository_before_request")
    assert_not_requested :post, /archive\.softwareheritage\.org/

    ENV["AFTER_ID"] = first.id.to_s
    Rake::Task["swhids:check_origins"].reenable
    capture_io { Rake::Task["swhids:check_origins"].invoke }
    assert_equal [[second.id]], CheckSwhidOriginWorker.jobs.map { |job| job["args"] }
  ensure
    %w[LIMIT AFTER_ID REQUESTS_ONLY].each { |key| previous&.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  test "origin backfill rejects an unbounded page" do
    previous = ENV["LIMIT"]
    ENV["LIMIT"] = "1001"
    assert_raises(ArgumentError) { Rake::Task["swhids:check_origins"].invoke }
    assert_empty CheckSwhidOriginWorker.jobs
  ensure
    previous ? ENV["LIMIT"] = previous : ENV.delete("LIMIT")
  end

  test "origin backfill includes projects that have not been scanned" do
    project = Project.create!(url: "https://github.com/coverage/unscanned", science_score: 42, repository: {})
    previous = ENV.to_h.slice("LIMIT", "AFTER_ID", "REQUESTS_ONLY")
    ENV["LIMIT"] = "100"
    ENV["AFTER_ID"] = "0"
    ENV["REQUESTS_ONLY"] = "false"

    capture_io { Rake::Task["swhids:check_origins"].invoke }

    assert_equal [[project.id]], CheckSwhidOriginWorker.jobs.map { |job| job["args"] }
    CheckSwhidOriginWorker.perform_one
    assert_equal "not_found", project.reload.swhids.dig("origin_archive", "status")
    assert project.swhid_scan_due?
    assert_not_requested :post, /archive\.softwareheritage\.org/
  ensure
    %w[LIMIT AFTER_ID REQUESTS_ONLY].each { |key| previous&.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  def coverage_project(name, status, classification, imported: false, request_id: 123)
    data = { "status" => "success", "origin" => "https://github.com/coverage/#{name}" }
    data["origin_archive"] = { "status" => status, "checked_at" => Time.current.iso8601 } if status
    data["archival"] = { "id" => request_id, "attribution_eligible" => true,
      "attempted_at" => 1.day.ago.iso8601, "save_task_status" => imported ? "succeeded" : "scheduled" }
    data["archival"]["repository_before_request"] = { "classification" => classification, "basis" => "pre_submission" } if classification
    Project.create!(url: data["origin"], repository: {}, science_score: 42, swhids: data)
  end
end
