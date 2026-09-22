require "test_helper"
require_relative "../support/swhid_pipeline"

class SwhidRateLimitTest < ActiveSupport::TestCase
  include SwhidPipeline
  REVISION = "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
  DIRECTORY = "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"
  ORIGIN = "https://github.com/simonehagey/orbdot"

  setup do
    travel_to Time.utc(2026, 9, 20, 15)
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    FetchSwhidWorker.jobs.clear
    CheckSwhidArchivalWorker.jobs.clear
    @data = {
      "status" => "success", "origin" => ORIGIN,
      "revision" => { "status" => "success", "swhid" => REVISION },
      "directory" => { "status" => "success", "swhid" => DIRECTORY }
    }
    @project = Project.create!(url: ORIGIN, science_score: 42, repository: { "clone_url" => ORIGIN }, swhids: @data)
    ProjectSwhidScanner.expects(:new).never
  end

  teardown do
    travel_back
    FetchSwhidWorker.jobs.clear
    CheckSwhidArchivalWorker.jobs.clear
  end

  test "submission rate limits defer both the rejected request and other projects" do
    lookup = known_request(false, false)
    submission = save_request.to_return(status: 429, headers: { "Retry-After" => "7200" })

    perform_fetch(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "rate_limited", request["status"]
    assert_equal "HTTP 429", request["error"]
    assert_nil request["id"]
    assert_equal false, request.dig("before_request", REVISION, "known")
    assert_retry_between CheckSwhidArchivalWorker.jobs.last, 2.hours.from_now
    assert_equal 2.hours.from_now.iso8601, request["retry_at"]

    other = Project.create!(url: "https://github.com/example/other", science_score: 42, repository: {}, swhids: @data)
    perform_fetch(other.id)
    assert_equal @data, other.reload.swhids
    assert_empty FetchSwhidWorker.jobs
    assert_retry_between CheckSwhidBatchWorker.jobs.last, 2.hours.from_now
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_requested submission, times: 1
    assert_requested lookup, times: 1
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
  end

  test "retry rechecks coverage and attributes only objects still missing before the accepted request" do
    known_request(false, false)
    save_request.to_return(status: 429, headers: { "Retry-After" => "7200" })
    perform_fetch(@project.id)
    first_attempt = @project.reload.swhids.dig("archival", "attempted_at")
    travel_to Time.iso8601(@project.swhids.dig("archival", "next_check_at")) + 1.second
    accepted_at = Time.current.iso8601
    known_request(true, false)
    submission = save_request.to_return(status: 200, body: api_result(date: accepted_at).to_json)

    CheckSwhidArchivalWorker.new.perform(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "pending", request["status"]
    assert_equal first_attempt, request["first_attempted_at"]
    assert_equal accepted_at, request["attempted_at"]
    assert_equal [DIRECTORY], request["before_request"].keys
    assert_equal false, @project.swhids.dig("revision", "archive", "first_check", "known")
    assert_nil request["error"]
    assert_nil request["retry_at"]

    travel 6.hours
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 200, body: api_result(task: "succeeded", date: accepted_at).to_json)
    known_request(true, true)
    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_equal [DIRECTORY], @project.reload.swhids.dig("archival", "confirmed_swhids")
    assert_equal({ "total" => 1, "revisions" => 0, "directories" => 1 }, SwhidArchiver.contribution_counts)
    assert_requested submission, times: 2
  end

  test "retry skips submission if all objects became known while waiting" do
    known_request(false, false)
    submission = save_request.to_return(status: 429, headers: { "Retry-After" => "3600" })
    perform_fetch(@project.id)
    travel 2.hours
    known_request(true, true)

    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_equal "not_needed", @project.reload.swhids.dig("archival", "status")
    assert_requested submission, times: 1
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
  end

  test "previously uncertain HTTP 429 submissions can be recovered without clearing their evidence" do
    known_request(false, false)
    save_request.to_return(status: 429)
    perform_fetch(@project.id)
    data = @project.reload.swhids.deep_dup
    data["archival"]["status"] = "uncertain"
    data["archival"]["next_check_at"] = 6.hours.from_now.iso8601
    @project.update!(swhids: data)
    @cache.clear
    save_request.to_return(status: 200, body: api_result.to_json)

    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_equal 123, @project.swhids.dig("archival", "id")
    assert_equal data.dig("archival", "before_request"), @project.swhids.dig("archival", "before_request")
    assert_equal false, @project.swhids.dig("revision", "archive", "first_check", "known")
  end

  test "HTTP-date Retry-After delays polling without resubmitting the origin" do
    known_request(false, false)
    submission = save_request.to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)
    travel 6.hours
    deadline = 1.day.from_now
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/")
      .to_return(status: 429, headers: { "Retry-After" => deadline.httpdate })

    CheckSwhidArchivalWorker.new.perform(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "pending", request["status"]
    assert_equal 123, request["id"]
    assert_equal deadline.iso8601, request["retry_at"]
    assert_retry_between CheckSwhidArchivalWorker.jobs.last, deadline
    assert_requested submission, times: 1
  end

  test "missing and invalid Retry-After values use a one hour fallback" do
    [nil, "not a date", "-1"].each do |header|
      @cache.clear
      @project.update!(swhids: @data.deep_dup)
      known_request(false, false)
      save_request.to_return(status: 429, headers: header ? { "Retry-After" => header } : {})

      perform_fetch(@project.id)

      assert_equal "rate_limited", @project.reload.swhids.dig("archival", "status")
      assert_retry_between CheckSwhidArchivalWorker.jobs.last, 1.hour.from_now
    end
  end

  test "zero Retry-After uses a minimum delay instead of immediately retrying" do
    known_request(false, false)
    save_request.to_return(status: 429, headers: { "Retry-After" => "0" })
    perform_fetch(@project.id)

    assert_retry_between CheckSwhidArchivalWorker.jobs.last, 1.minute.from_now
  end

  test "coverage rate limits persist the server deadline and schedule a worker" do
    lookup = stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 429, headers: { "Retry-After" => "25200" })

    perform_fetch(@project.id)

    assert_equal "error", @project.reload.swhids.dig("revision", "archive", "status")
    assert_equal 7.hours.from_now.iso8601, @project.swhids.dig("revision", "archive", "retry_at")
    assert_retry_between CheckSwhidBatchWorker.jobs.last, 7.hours.from_now
    travel 2.hours
    assert_nil @project.fetch_swhids_async
    assert_requested lookup, times: 1

    travel 6.hours
    known_request(true, true)
    perform_fetch(@project.id)
    assert_equal "archived", @project.reload.swhids.dig("revision", "archive", "status")
    assert_nil @project.swhids.dig("revision", "archive", "retry_at")
  end

  test "final coverage rate limits preserve the accepted request and reschedule confirmation" do
    known_request(false, false)
    save_request.to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)
    travel 6.hours
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 200, body: api_result(task: "succeeded").to_json)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 429, headers: { "Retry-After" => "86400" })

    CheckSwhidArchivalWorker.new.perform(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "pending", request["status"]
    assert_equal 123, request["id"]
    assert_equal true, request["attribution_eligible"]
    assert_retry_between CheckSwhidArchivalWorker.jobs.last, 1.day.from_now

    travel 25.hours
    known_request(true, true)
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_equal "completed", @project.reload.swhids.dig("archival", "status")
    assert_equal 2, SwhidArchiver.contribution_counts["total"]
  end

  test "rate limiting the coverage recheck postpones resubmission without losing its evidence" do
    known_request(false, false)
    submission = save_request.to_return(status: 429, headers: { "Retry-After" => "60" })
    perform_fetch(@project.id)
    evidence = @project.reload.swhids.dig("archival", "before_request")
    travel 1.hour
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 429, headers: { "Retry-After" => "25200" })

    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_equal evidence, @project.reload.swhids.dig("archival", "before_request")
    assert_equal "rate_limited", @project.swhids.dig("archival", "status")
    assert_retry_between FetchSwhidWorker.jobs.last, 7.hours.from_now
    assert_requested submission, times: 1

    travel 8.hours
    known_request(false, false)
    save_request.to_return(status: 200, body: api_result(date: Time.current.iso8601).to_json)
    perform_fetch(@project.id)

    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_equal 123, @project.swhids.dig("archival", "id")
  end

  test "an in-flight response cannot shorten an already recorded longer cooldown" do
    known_request(false, false)
    deadline = 1.day.from_now
    save_request.to_return do
      @cache.write(SwhidApi::COOLDOWN_KEY, deadline.to_f)
      { status: 429, headers: { "Retry-After" => "60" } }
    end

    perform_fetch(@project.id)

    assert_equal deadline.iso8601, @project.reload.swhids.dig("archival", "retry_at")
    assert_retry_between CheckSwhidArchivalWorker.jobs.last, deadline
  end

  def known_request(revision, directory)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).with(body: [REVISION, DIRECTORY].to_json)
      .to_return(status: 200, body: { REVISION => { known: revision }, DIRECTORY => { known: directory } }.to_json)
  end

  def save_request
    stub_request(:post, SwhidArchiver::ENDPOINT).with(query: { "visit_type" => "git", "origin_url" => ORIGIN })
  end

  def api_result(task: "scheduled", date: Time.utc(2026, 9, 20, 15).iso8601)
    { "id" => 123, "origin_url" => ORIGIN, "visit_type" => "git", "save_request_date" => date,
      "save_request_status" => "accepted", "save_task_status" => task }
  end

  def assert_retry_between(job, deadline)
    assert_operator job.fetch("at"), :>, deadline.to_f
    assert_operator job.fetch("at"), :<=, deadline.to_f + 300
  end
end
