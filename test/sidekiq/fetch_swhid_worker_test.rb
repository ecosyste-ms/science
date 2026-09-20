require "test_helper"
require "tmpdir"
require "open3"

class FetchSwhidWorkerTest < ActiveSupport::TestCase
  setup do
    FetchSwhidWorker.jobs.clear
    @directory = Dir.mktmpdir("science-swhid-test-")
    @repository = File.join(@directory, "source with spaces")
    FileUtils.mkdir_p(@repository)
    git("init", @repository)
    File.write(File.join(@repository, "hello.txt"), "hello\n")
    File.write(File.join(@repository, "run"), "#!/bin/sh\nexit 0\n")
    File.chmod(0755, File.join(@repository, "run"))
    File.symlink("hello.txt", File.join(@repository, "link"))
    git("-C", @repository, "add", ".")
    git("-C", @repository, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Test input")
    @project = Project.create!(url: "https://github.com/test/swhid-input", repository: { "clone_url" => @repository }, science_score: 42)
  end

  teardown do
    FetchSwhidWorker.jobs.clear
    FileUtils.remove_entry(@directory)
  end

  test "worker stores real CLI revision and directory results without changing score" do
    commit = git("-C", @repository, "rev-parse", "HEAD").strip
    tree = git("-C", @repository, "rev-parse", "HEAD^{tree}").strip
    request = stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .with(body: ["swh:1:rev:#{commit}", "swh:1:dir:#{tree}"].to_json, headers: { "Content-Type" => "application/json", "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)" })
      .to_return(status: 200, body: {
        "swh:1:rev:#{commit}" => { "known" => true },
        "swh:1:dir:#{tree}" => { "known" => false }
      }.to_json)
    @project.fetch_swhids_async
    assert_equal [[@project.id]], FetchSwhidWorker.jobs.map { |job| job["args"] }
    FetchSwhidWorker.drain

    result = @project.reload.swhids
    assert_equal "success", result["status"]
    assert_equal commit, result["commit"]
    assert_equal @repository, result["origin"]
    assert_equal "swh:1:rev:#{commit}", result.dig("revision", "swhid")
    assert_equal "swh:1:dir:#{tree}", result.dig("directory", "swhid")
    assert_match(/swhid .*0\.1\.0/, result.dig("revision", "binary_version"))
    assert_equal "swhid-go/revision", result.dig("revision", "method")
    assert_kind_of Array, result.dig("revision", "command")
    assert_operator result["duration_ms"], :>=, 0
    assert_equal 42, @project.science_score
    assert_not File.exist?(result.dig("directory", "input", "path"))
    assert_equal "archived", result.dig("revision", "archive", "status")
    assert_equal "not_found", result.dig("directory", "archive", "status")
    assert result.dig("revision", "archive", "checked_at")
    assert_requested request, times: 1
  end

  test "worker records an unavailable repository without enqueuing another scan" do
    @project.update!(repository: { "clone_url" => File.join(@directory, "missing") })
    FetchSwhidWorker.new.perform(@project.id)
    result = @project.reload.swhids
    assert_equal "error", result["status"]
    assert_includes result["error"], "does not exist"
    assert_operator result["error"].length, :<=, 500
    @project.fetch_swhids_async
    assert_empty FetchSwhidWorker.jobs
  end

  test "uses a low priority queue with the same retry setting as Brief" do
    assert_equal "swhid", FetchSwhidWorker.get_sidekiq_options["queue"]
    assert_equal 3, FetchSwhidWorker.get_sidekiq_options["retry"]
  end

  test "duplicate jobs skip a stored result or error" do
    [{ "status" => "success" }, { "status" => "error", "error" => "timeout" }].each do |result|
      @project.update!(swhids: result)
      ProjectSwhidScanner.expects(:new).never
      FetchSwhidWorker.new.perform(@project.id)
      assert_equal result, @project.reload.swhids
    end
  end

  test "worker rechecks scientific eligibility and repository metadata" do
    ProjectSwhidScanner.expects(:new).never
    @project.update!(science_score: Project::SCIENCE_SCORE_THRESHOLD - 1)
    FetchSwhidWorker.new.perform(@project.id)
    assert_nil @project.reload.swhids
    @project.update!(science_score: 42, repository: nil)
    FetchSwhidWorker.new.perform(@project.id)
    assert_nil @project.reload.swhids
  end

  test "worker skips deleted and newly hidden projects" do
    ProjectSwhidScanner.expects(:new).never
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "test")
    @project.update!(owner_record: owner)
    owner.update!(hidden: true)
    FetchSwhidWorker.new.perform(@project.id)
    assert_nil @project.reload.swhids
    @project.destroy!
    assert_nil FetchSwhidWorker.new.perform(@project.id)
  end

  def git(*args)
    output, error, status = Open3.capture3("git", *args)
    assert status.success?, error
    output
  end
end
