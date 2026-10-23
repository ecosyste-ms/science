require "test_helper"
require_relative "../support/swhid_pipeline"
require "rake"

class BriefRescanRakeTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:rescan_brief")
    @previous_limit = ENV.delete("LIMIT")
    BriefRescanEnqueuer.stubs(:current_version).returns(Gem::Version.new("0.14.1"))
  end

  teardown do
    @previous_limit ? ENV["LIMIT"] = @previous_limit : ENV.delete("LIMIT")
  end

  test "enqueues only completed older eligible scans regardless of README contents" do
    old = project("old")
    project("current", version: "0.14.1")
    project("newer", version: "0.15.0")
    project("invalid", version: "unknown")
    project("missing", version: nil)
    project("unscanned").update!(brief: nil)
    project("legacy").update!(brief: { "version" => "0.12.0" })
    project("error").update!(brief: { "version" => "0.14.0", "dependencies" => [], "error" => "timeout" })
    project("failed-refresh").update!(brief: { "version" => "0.14.0", "dependencies" => [], "last_error" => { "error" => "timeout" } })
    no_readme = project("no-readme").tap { |record| record.update!(readme: nil) }
    no_bibtex = project("no-bibtex").tap { |record| record.update!(readme: "Contact @example for details.") }
    project("no-repository").update!(repository: nil)
    project("zero-score").update!(science_score: 0)
    hidden = project("hidden")
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "bibtex-hidden")
    hidden.update!(owner_record: owner)
    owner.update!(hidden: true)

    result = run_task

    assert_equal "0.14.1", result.fetch("installed_version")
    assert_equal 3, result.fetch("enqueued")
    assert_equal [old.id, no_readme.id, no_bibtex.id], result.fetch("projects").map { |row| row.fetch("id") }
    assert_equal "0.14.0", old.reload.brief.fetch("version")
    assert_equal 3, RepositoryScanWorker.jobs.size
  end

  test "enqueue is bounded ordered and does not duplicate waiting jobs" do
    first = project("first", version: "0.9.0")
    second = project("second", version: "0.12.1")
    project("third")
    ENV["LIMIT"] = "2"

    result = run_task
    repeated = run_task

    assert_equal 2, result.fetch("enqueued")
    assert_equal 0, repeated.fetch("enqueued")
    assert_equal [[first.id, false, true], [second.id, false, true]], RepositoryScanWorker.jobs.map { |job| job.fetch("args") }
  end

  test "default limit is 100" do
    101.times { |index| project("limit-#{index}") }
    assert_equal 100, run_task.fetch("selected")
    assert_equal 100, RepositoryScanWorker.jobs.size
  end

  test "invalid options do not enqueue" do
    project("invalid-options")
    %w[0 -1 many].each do |limit|
      ENV["LIMIT"] = limit
      capture_io { assert_raises(SystemExit) { Rake::Task["projects:rescan_brief"].execute } }
    end
    assert_empty RepositoryScanWorker.jobs
  end

  test "selection follows the installed version after an upgrade" do
    current = project("upgraded", version: "0.14.1")
    project("future", version: "0.15.0")
    assert_equal 0, run_task.fetch("enqueued")

    BriefRescanEnqueuer.stubs(:current_version).returns(Gem::Version.new("0.15.0"))

    result = run_task
    assert_equal "0.15.0", result.fetch("installed_version")
    assert_equal [current.id], result.fetch("projects").map { |row| row.fetch("id") }
  end

  test "reads the installed executable version and fails closed on invalid output" do
    BriefRescanEnqueuer.unstub(:current_version)
    RepositoryCommand.any_instance.expects(:run).with(["brief", "--version"]).returns("brief 0.14.1\n")
    assert_equal "0.14.1", run_task.fetch("installed_version")

    RepositoryCommand.any_instance.expects(:run).with(["brief", "--version"]).returns("unexpected output\n")
    capture_io { assert_raises(SystemExit) { Rake::Task["projects:rescan_brief"].execute } }
    assert_empty RepositoryScanWorker.jobs
  end

  test "worker uses its own installed version if the task ran on a newer installation" do
    project("mixed-deployment", version: "0.14.1")
    BriefRescanEnqueuer.stubs(:current_version).returns(Gem::Version.new("0.15.0"))
    assert_equal 1, run_task.fetch("enqueued")
    BriefRescanEnqueuer.stubs(:current_version).returns(Gem::Version.new("0.14.1"))
    ProjectRepositoryScanner.expects(:new).never
    RepositoryScanWorker.drain
  end

  test "worker skips refreshed failed hidden and newly ineligible projects" do
    %w[refreshed failed ineligible hidden].each do |name|
      record = project("changed-#{name}")
      RepositoryScanWorker.perform_async(record.id, false, true)
      case name
      when "refreshed" then record.update!(brief: { "version" => "0.14.1", "dependencies" => [] })
      when "failed" then record.update!(brief: { "error" => "timeout" })
      when "ineligible" then record.update!(science_score: 0)
      when "hidden"
        owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "changed-hidden")
        record.update!(owner_record: owner)
        owner.update!(hidden: true)
      end
    end
    ProjectRepositoryScanner.expects(:new).never
    RepositoryScanWorker.drain
  end

  def run_task
    output, = capture_io { Rake::Task["projects:rescan_brief"].execute }
    JSON.parse(output)
  end

  def project(name, version: "0.14.0")
    Project.create!(url: "https://github.com/test/bibtex-rescan-#{name}", science_score: 50,
      repository: { "clone_url" => "https://github.com/test/bibtex-rescan-#{name}.git" },
      readme: "# Example\n```bibtex\n@ARTICLE{example, title={Example}}\n```",
      brief: { "version" => version, "dependencies" => [] })
  end
end
