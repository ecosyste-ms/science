require "test_helper"
require_relative "../support/swhid_pipeline"
require "rake"

class BriefScanRakeTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:fetch_brief")
    @previous_env = ENV.to_h.slice("LIMIT", "COHORT", "SHARD_COUNT", "SHARD")
    %w[LIMIT COHORT SHARD_COUNT SHARD].each { |key| ENV.delete(key) }
  end

  teardown do
    %w[LIMIT COHORT SHARD_COUNT SHARD].each { |key| ENV[key] = @previous_env[key] }
  end

  test "first scans precede older retries and share one batch limit" do
    retry_project = project("retry", brief: { "error" => "timeout", "attempted_at" => 8.days.ago.iso8601 })
    project("retry-over-limit", brief: { "error" => "timeout" })
    first = project("first")
    legacy = project("legacy", brief: { "version" => "0.12.0" })
    ENV["LIMIT"] = "3"

    output, = capture_io { Rake::Task["projects:fetch_brief"].execute }

    assert_includes output, "Enqueued 3 Brief jobs"
    assert_equal [[first.id], [legacy.id], [retry_project.id]], RepositoryScanWorker.jobs.map { |job| job.fetch("args") }
  end

  test "a full first-scan batch does not enqueue retries" do
    project("retry", brief: { "error" => "timeout" })
    first = project("first")
    project("later")
    ENV["LIMIT"] = "1"

    capture_io { Rake::Task["projects:fetch_brief"].execute }

    assert_equal [[first.id]], RepositoryScanWorker.jobs.map { |job| job.fetch("args") }
  end

  test "retry cooldown and exclusions survive separate selection" do
    travel_to Time.utc(2026, 10, 26, 12) do
      due = project("due", brief: { "error" => "timeout", "attempts" => 2, "attempted_at" => 14.days.ago.iso8601 })
      legacy = project("legacy-error", brief: { "error" => "timeout" })
      project("cooldown", brief: { "error" => "timeout", "attempts" => 2, "attempted_at" => 13.days.ago.iso8601 })
      project("exhausted", brief: { "error" => "timeout", "attempts" => 3, "attempted_at" => 30.days.ago.iso8601 })
      project("too-large", brief: { "error" => Project::BRIEF_TOO_LARGE_ERROR })
      project("completed-error", brief: { "error" => "timeout", "dependencies" => [] })
      project("completed", brief: { "dependencies" => [] })
      project("gated-first", brief: { "status" => "gated" })
      project("gated-retry", brief: { "status" => "gated", "error" => "timeout" })
      project("missing-repository", brief: { "error" => "timeout" }).update!(repository: nil)
      owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "hidden-brief")
      project("hidden", brief: { "error" => "timeout" }).update!(owner_record: owner)
      owner.update!(hidden: true)

      capture_io { Rake::Task["projects:fetch_brief"].execute }

      assert_equal [[due.id], [legacy.id]], RepositoryScanWorker.jobs.map { |job| job.fetch("args") }
      assert_equal [due.id, legacy.id], Project.visible.with_repository.needing_brief_dependencies.order(:id).pluck(:id)
    end
  end

  test "cohort and shard apply to both first scans and retries" do
    records = 8.times.map do |index|
      project("shard-#{index}", brief: index < 4 ? { "error" => "timeout" } : nil)
    end
    records.each { |record| record.update!(joss_metadata: { "doi" => "10.21105/joss.test" }) }
    project("other-cohort", brief: { "error" => "timeout" })
    project("other-cohort-first")
    ENV.update("LIMIT" => "10", "COHORT" => "joss", "SHARD_COUNT" => "2", "SHARD" => "0")

    capture_io { Rake::Task["projects:fetch_brief"].execute }

    expected = (records.last(4) + records.first(4)).select { |record| record.id.even? }
    assert_equal expected.map { |record| [record.id] }, RepositoryScanWorker.jobs.map { |job| job.fetch("args") }
  end

  def project(name, brief: nil)
    Project.create!(url: "https://github.com/test/brief-task-#{name}", science_score: 20,
      repository: { "clone_url" => "https://github.com/test/brief-task-#{name}.git" }, brief: brief)
  end
end
