require "test_helper"
require "tmpdir"
require "open3"
require_relative "../support/swhid_pipeline"

class CheckSwhidHistoryWorkerTest < ActionDispatch::IntegrationTest
  include SwhidPipeline

  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @directory = Dir.mktmpdir("science-history-test-")
    @repository = File.join(@directory, "source")
    git("init", @repository)
    @commits = %w[A B C].map { |name| commit(name) }
    @project = create_project("first")
    @temporary_before = Dir.glob(File.join(Dir.tmpdir, "science-swh-history-*"))
  end

  teardown do
    assert_equal @temporary_before, Dir.glob(File.join(Dir.tmpdir, "science-swh-history-*"))
    FileUtils.remove_entry(@directory)
  end

  test "worker finds archived B behind missing C and exposes stored evidence through the API" do
    request = known_request
    before = @project.swhids.deep_dup
    run_history(@project)

    history = @project.reload.swhids.fetch("history_archive")
    assert_equal "complete", history["status"]
    assert_equal true, history["complete"]
    assert_equal @commits.last, history["starting_commit"]
    assert_equal 2, history["checked_count"]
    assert_equal [swhid(@commits[1])], archived(history)
    assert_equal before, @project.swhids.except("history_archive")
    assert_requested request, times: 1
    assert_not_requested :post, SwhidArchiver::ENDPOINT
    assert_empty CheckSwhidArchivalWorker.jobs
    jobs = Sidekiq::Worker.jobs.deep_dup
    get "/api/v1/projects/#{@project.id}/swhids"
    assert_response :success
    evidence = response.parsed_body.fetch("history_archive")
    assert_equal "complete", evidence["status"]
    assert_equal @commits.last, evidence["starting_commit"]
    assert_equal [swhid(@commits[1])], archived(evidence)
    assert_equal "not_found", response.parsed_body["objects"].first.dig("archive", "status")
    assert_not_includes response.body, @directory
    assert_equal jobs, Sidekiq::Worker.jobs
  end

  test "batch deduplicates shared ancestors across projects" do
    second = create_project("second")
    request = known_request
    run_history(@project, second)

    assert_requested request, times: 1
    [@project, second].each do |project|
      assert_equal [swhid(@commits[1])], archived(project.reload.swhids.fetch("history_archive"))
    end
    assert_equal "swhid", CheckSwhidHistoryWorker.get_sidekiq_options["queue"]
    assert_equal "swh_api", CheckSwhidHistoryBatchWorker.get_sidekiq_options["queue"]
  end

  test "truncated history resumes from the saved commit after the default branch advances" do
    stub_const(SwhidHistoryChecker, :FETCH_STEP, 2) do
      known_request([@commits[1]])
      run_history(@project)
      initial = @project.reload.swhids.fetch("history_archive").deep_dup
      assert_equal false, initial["complete"]
      assert_equal false, initial["history_complete"]
      assert_equal "shallow_history", initial["reason"]
      assert_equal 1, initial["checked_count"]
      newer = commit("D")
      @project.store_swhids(@project.swhids.except("history_archive").merge("commit" => newer))
      assert_equal initial, @project.reload.swhids["history_archive"]
      request = known_request([@commits[0]])

      run_history(@project)

      history = @project.reload.swhids.fetch("history_archive")
      assert_equal @commits.last, history["starting_commit"]
      assert_equal true, history["complete"]
      assert_equal 2, history["checked_count"]
      assert_equal initial["revisions"].first, history["revisions"].first
      assert_equal newer, @project.swhids["commit"]
      assert_requested request, times: 1
      assert_not_includes history["revisions"].pluck("swhid"), swhid(newer)
    end
  end

  test "fallback clone origin stays pinned when repository metadata changes" do
    @project.update!(swhids: @project.swhids.except("origin"))
    stub_const(SwhidHistoryChecker, :FETCH_STEP, 2) do
      known_request([@commits[1]])
      run_history(@project)
      assert_equal @repository, @project.reload.swhids.dig("history_archive", "origin")
      @project.update!(repository: { "clone_url" => File.join(@directory, "missing") })
      known_request([@commits.first])
      run_history(@project)
      assert_equal true, @project.reload.swhids.dig("history_archive", "complete")
    end
  end

  test "identifier limit stays incomplete even when all checked ancestors are missing" do
    stub_const(SwhidHistoryChecker, :MAX_REVISIONS, 1) do
      known_request([@commits[1]], archived: nil)
      run_history(@project)
      history = @project.reload.swhids.fetch("history_archive")
      assert_equal false, history["complete"]
      assert_equal "identifier_limit", history["reason"]
      assert_empty archived(history)
      run_history(@project)
      assert_equal history, @project.reload.swhids["history_archive"]
    end
  end

  test "exhausted history with no matches is complete" do
    known_request(archived: nil)
    run_history(@project)
    history = @project.reload.swhids.fetch("history_archive")
    assert_equal true, history["complete"]
    assert_empty archived(history)
  end

  test "API batches resume saved identifiers without another fetch" do
    stub_const(SwhidHistoryChecker, :MAX_CHECKS, 1) do
      first = known_request([@commits[1]])
      run_history(@project)
      assert_equal false, @project.reload.swhids.dig("history_archive", "complete")
      @project.update!(repository: { "clone_url" => "/does/not/exist" })
      second = known_request([@commits[0]])
      SwhidHistoryChecker.any_instance.expects(:run).never
      run_history(@project)

      assert_equal true, @project.reload.swhids.dig("history_archive", "complete")
      assert_requested first, times: 1
      assert_requested second, times: 1
    end
  end

  test "rate limits schedule API retry with saved identifiers and shared cooldown" do
    request = stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 429, headers: { "Retry-After" => "3600" })
    run_history(@project)
    history = @project.reload.swhids.fetch("history_archive")
    assert_equal "incomplete", history["status"]
    assert_equal "api_error", history["reason"]
    assert history["revisions"].all? { |object| object.dig("archive", "retry_at") }
    assert_equal 1, CheckSwhidHistoryBatchWorker.jobs.size
    retry_job = CheckSwhidHistoryBatchWorker.jobs.first
    assert_operator retry_job["at"], :>=, 1.hour.from_now.to_f - 1
    CheckSwhidHistoryBatchWorker.perform_one
    assert_requested request, times: 1

    travel 2.hours do
      success = known_request
      CheckSwhidHistoryBatchWorker.perform_one
      assert_equal true, @project.reload.swhids.dig("history_archive", "complete")
      assert_requested success, times: 2
      assert_empty CheckSwhidHistoryWorker.jobs
    end
  end

  test "API failures retain incomplete evidence and can retry without cloning" do
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 503)
    run_history(@project)
    assert_equal false, @project.reload.swhids.dig("history_archive", "complete")
    assert_equal 0, @project.swhids.dig("history_archive", "checked_count")
    SwhidHistoryChecker.any_instance.expects(:run).never
    known_request
    run_history(@project)
    assert_equal true, @project.reload.swhids.dig("history_archive", "complete")
  end

  test "fetch failure removes checkout and retains the pinned starting commit for retry" do
    @project.update!(swhids: @project.swhids.merge("origin" => File.join(@directory, "missing")))
    run_history(@project)
    history = @project.reload.swhids.fetch("history_archive")
    assert_equal "fetch_failed", history["reason"]
    assert_equal false, history["complete"]
    assert_equal @commits.last, history["starting_commit"]
    assert_empty CheckSwhidHistoryBatchWorker.jobs
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  end

  test "depth limit records incomplete history without silently restarting" do
    stub_const(SwhidHistoryChecker, :MAX_DEPTH, 2) do
      known_request([@commits[1]])
      run_history(@project)
      history = @project.reload.swhids.fetch("history_archive")
      assert_equal false, history["complete"]
      assert_equal "depth_limit", history["reason"]
      assert_equal 2, history["depth"]
      SwhidHistoryChecker.any_instance.expects(:run).never
      run_history(@project)
      assert_equal history, @project.reload.swhids["history_archive"]
    end
  end

  test "a root commit completes with no ancestors or API requests" do
    @project.update!(swhids: @project.swhids.merge("commit" => @commits.first))
    run_history(@project)
    history = @project.reload.swhids.fetch("history_archive")
    assert_equal true, history["complete"]
    assert_equal 0, history["checked_count"]
    assert_empty history["revisions"]
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  end

  test "history includes ancestors from both parents of a merge" do
    git("-C", @repository, "checkout", "-b", "other", @commits.first)
    File.write(File.join(@repository, "other.txt"), "other branch\n")
    other = commit("other")
    git("-C", @repository, "checkout", "--detach", @commits.last)
    git("-C", @repository, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "merge", "-s", "ours", "--no-ff", "-m", "merge", "other")
    merged = git("-C", @repository, "rev-parse", "HEAD").strip
    @project.update!(swhids: @project.swhids.merge("commit" => merged))
    request = stub_request(:post, SwhidArchiveChecker::ENDPOINT).with do |request|
      JSON.parse(request.body).sort == (@commits + [other]).map { |sha| swhid(sha) }.sort
    end.to_return(body: (@commits + [other]).to_h { |sha| [swhid(sha), { known: sha == other }] }.to_json)

    run_history(@project)

    history = @project.reload.swhids.fetch("history_archive")
    assert_equal true, history["complete"]
    assert_equal [swhid(other)], archived(history)
    assert_equal 4, history["checked_count"]
    assert_requested request, times: 1
  end

  test "disk and runtime limits interrupt fetching and remove checkout" do
    [[:MAX_DISK_BYTES, 1], [:TIMEOUT, 0]].each do |constant, limit|
      @project.update!(swhids: @project.swhids.except("history_archive"))
      stub_const(SwhidHistoryChecker, constant, limit) do
        run_history(@project)
        history = @project.reload.swhids.fetch("history_archive")
        assert_equal false, history["complete"]
        assert_equal "fetch_failed", history["reason"]
        assert_match(/limit exceeded/, history["error"])
      end
    end
  end

  test "SHA256 commits are unsupported without making archive requests" do
    @project.update!(swhids: @project.swhids.merge("commit" => "a" * 64))
    run_history(@project)
    assert_equal "unsupported", @project.reload.swhids.dig("history_archive", "status")
    assert_equal "unsupported_object_format", @project.swhids.dig("history_archive", "reason")
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  end

  test "history reset during API request discards stale results" do
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return do
      @project.update!(swhids: @project.reload.swhids.except("history_archive"))
      { body: @commits.first(2).to_h { |commit| [swhid(commit), { known: true }] }.to_json }
    end
    run_history(@project)
    assert_nil @project.reload.swhids["history_archive"]
  end

  test "unscanned or ineligible projects do not queue history checks" do
    @project.update!(science_score: 0)
    run_history(@project)
    assert_nil @project.reload.swhids["history_archive"]
    @project.update!(science_score: 42, swhids: @project.swhids.except("origin_archive"))
    run_history(@project)
    assert_nil @project.reload.swhids["history_archive"]
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  end

  def run_history(*projects)
    CheckSwhidHistoryWorker.perform_async(projects.map(&:id))
    CheckSwhidHistoryWorker.perform_one
    CheckSwhidHistoryBatchWorker.perform_one if CheckSwhidHistoryBatchWorker.jobs.any?
  end

  def create_project(name)
    Project.create!(url: "https://github.com/history/#{name}", repository: { "clone_url" => @repository }, science_score: 42,
      swhids: { "status" => "success", "commit" => @commits.last, "origin" => @repository,
        "revision" => { "status" => "success", "swhid" => swhid(@commits.last),
          "archive" => { "status" => "not_found", "checked_at" => Time.current.iso8601 } },
        "origin_archive" => { "status" => "archived" } })
  end

  def known_request(commits = @commits.first(2).reverse, archived: @commits[1])
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).with(body: commits.map { |commit| swhid(commit) }.to_json)
      .to_return(body: commits.to_h { |commit| [swhid(commit), { known: commit == archived }] }.to_json)
  end

  def archived(history)
    history["revisions"].select { |object| object.dig("archive", "status") == "archived" }.pluck("swhid")
  end

  def swhid(commit)
    "swh:1:rev:#{commit}"
  end

  def commit(name)
    File.write(File.join(@repository, "README.md"), "# #{name}\n")
    git("-C", @repository, "add", ".")
    git("-C", @repository, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", name)
    git("-C", @repository, "rev-parse", "HEAD").strip
  end

  def git(*args)
    output, error, status = Open3.capture3("git", *args)
    assert status.success?, error
    output
  end
end
