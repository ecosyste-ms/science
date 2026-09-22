require "test_helper"
require_relative "../support/swhid_pipeline"
require "tmpdir"
require "open3"

class RepositoryScanWorkerTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    @directory = Dir.mktmpdir("science-repository-test-")
    @source = File.join(@directory, "source with spaces")
    FileUtils.mkdir_p(@source)
    git("init", @source)
    File.write(File.join(@source, "requirements.txt"), "numpy==2.0.0\n")
    File.write(File.join(@source, "main.py"), "import numpy\nprint(numpy.zeros(3))\n")
    File.write(File.join(@source, "main.f90"), "program hello\nprint *, 'hello'\nend program hello\n")
    File.write(File.join(@source, "codemeta.json"), '{"name":"Research software"}')
    git("-C", @source, "add", ".")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Repository input")
    @commit = git("-C", @source, "rev-parse", "HEAD").strip
    @project = Project.create!(url: "https://github.com/test/shared-checkout", science_score: 50,
      joss_metadata: { "title" => "Research software" }, repository: { "clone_url" => @source })
    @previous_trace = ENV["GIT_TRACE2_EVENT"]
    @previous_path = ENV["PATH"]
    @trace = File.join(@directory, "git-trace.jsonl")
    ENV["GIT_TRACE2_EVENT"] = @trace
  end

  teardown do
    @previous_trace ? ENV["GIT_TRACE2_EVENT"] = @previous_trace : ENV.delete("GIT_TRACE2_EVENT")
    ENV["PATH"] = @previous_path
    FileUtils.remove_entry(@directory)
  end

  test "Brief selection and project sync share one queued scan and one real checkout" do
    assert_equal 1, BriefScanEnqueuer.new(limit: 1).enqueue
    assert_nil @project.fetch_swhids_async
    assert_equal 1, RepositoryScanWorker.jobs.size

    RepositoryScanWorker.perform_one

    @project.reload
    assert @project.brief.fetch("dependencies").any? { |dependency| dependency["purl"] == "pkg:pypi/numpy" }
    assert_equal "success", @project.swhids["status"]
    assert_equal "swh:1:rev:#{@commit}", @project.swhids.dig("revision", "swhid")
    assert_equal @commit, @project.swhids.fetch("commit")
    assert @project.swhids.dig("metadata", "codemeta", "content_swhid")
    assert_equal 1, clone_commands.size
    checkout = @project.swhids.dig("directory", "input", "path")
    assert_equal checkout, clone_commands.first.last
    assert_not File.exist?(checkout)
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    assert_equal "swh_api", CheckSwhidBatchWorker.jobs.first["queue"]
    assert_not_requested :any, /archive\.softwareheritage\.org/
  end

  test "queued legacy workers use the shared checkout and skip completed analyses" do
    FetchBriefWorker.new.perform(@project.id)
    FetchSwhidWorker.new.perform(@project.id)
    RepositoryScanWorker.new.perform(@project.id)

    assert_equal 1, clone_commands.size
    assert_equal "success", @project.reload.swhids["status"]
    assert @project.brief.key?("dependencies")
  end

  test "Brief can promote a project and calculate SWHIDs using the same checkout" do
    @project.update!(science_score: 1, joss_metadata: nil)

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_operator @project.reload.science_score, :>=, Project::SCIENCE_SCORE_THRESHOLD
    assert_equal "success", @project.swhids["status"]
    assert_equal 1, clone_commands.size
  end

  test "Brief runs without replacing stored SWHIDs or archival evidence" do
    original = { "status" => "success", "origin_archive" => { "status" => "archived" },
      "archival" => { "id" => 123, "status" => "completed" } }
    @project.update!(swhids: original)
    SwhidCalculator.any_instance.expects(:calculate).never

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_equal original, @project.reload.swhids
    assert @project.brief.key?("dependencies")
    assert_equal 1, clone_commands.size
  end

  test "a Brief command failure preserves successful SWHIDs and removes the checkout" do
    failing_binary("brief")

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_match "analysis failed", @project.reload.brief["error"]
    assert_equal "success", @project.swhids["status"]
    assert_equal 1, clone_commands.size
    assert_not File.exist?(@project.swhids.dig("directory", "input", "path"))
  end

  test "a SWHID command failure still saves Brief results" do
    failing_binary("swhid")

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_equal "error", @project.reload.swhids["status"]
    assert @project.brief.key?("dependencies")
    assert_equal 1, clone_commands.size
    assert_not File.exist?(clone_commands.first.last)
  end

  test "clone failures are recorded for both due analyses without replacing origin coverage" do
    coverage = { "status" => "archived", "checked_at" => Time.current.iso8601 }
    @project.update!(repository: { "clone_url" => File.join(@directory, "missing") },
      swhids: { "origin_archive" => coverage })

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one
    RepositoryScanWorker.new.perform(@project.id)

    assert_match "does not exist", @project.reload.brief["error"]
    assert_equal "error", @project.swhids["status"]
    assert_equal coverage, @project.swhids["origin_archive"]
    assert_equal 1, clone_commands.size
    assert_not File.exist?(clone_commands.first.last)
  end

  test "a project lock prevents legacy and new workers from overlapping scans" do
    options = Project.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password)
    connection = PG.connect(options)
    assert_equal "science_test", connection.db
    key = "#{RepositoryScanWorker::LOCK_NAMESPACE}, #{@project.id}"
    connection.exec("SELECT pg_advisory_lock(#{key})")

    FetchBriefWorker.new.perform(@project.id)
    FetchSwhidWorker.new.perform(@project.id)
    RepositoryScanWorker.new.perform(@project.id)

    assert_empty clone_commands
    assert_nil @project.reload.brief
    assert_nil @project.swhids
    connection.exec("SELECT pg_advisory_unlock(#{key})")
    RepositoryScanWorker.new.perform(@project.id)
    assert_equal "success", @project.reload.swhids["status"]
  ensure
    connection&.close
  end

  test "API retries use stored identifiers without cloning or running Brief" do
    @project.update!(swhids: { "status" => "success", "revision" => {
      "status" => "success", "swhid" => "swh:1:rev:#{@commit}" } })

    CheckSwhidWorker.perform_async(@project.id)
    CheckSwhidWorker.perform_one

    assert_empty clone_commands
    assert_nil @project.reload.brief
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    assert_equal "swh_api", CheckSwhidWorker.get_sidekiq_options["queue"]
  end

  test "projects below both selection thresholds are not cloned" do
    @project.update!(science_score: 0, joss_metadata: nil)

    RepositoryScanWorker.new.perform(@project.id)

    assert_empty clone_commands
    assert_nil @project.reload.brief
    assert_nil @project.swhids
  end

  def failing_binary(name)
    directory = File.join(@directory, "bin")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, name)
    File.write(path, "#!/bin/sh\necho 'analysis failed' >&2\nexit 1\n")
    File.chmod(0755, path)
    ENV["PATH"] = "#{directory}:#{@previous_path}"
  end

  def clone_commands
    return [] unless File.exist?(@trace)

    File.readlines(@trace).map { |line| JSON.parse(line) }
      .select { |event| event["event"] == "start" && event["argv"]&.include?("clone") }
      .map { |event| event.fetch("argv") }
  end

  def git(*args)
    output, error, status = Open3.capture3("git", *args)
    assert status.success?, error
    output
  end
end
