require "test_helper"
require_relative "../support/swhid_pipeline"

class SwhidArchivalTest < ActiveSupport::TestCase
  include SwhidPipeline
  REVISION = "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
  DIRECTORY = "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"
  ORIGIN = "https://github.com/simonehagey/orbdot"

  setup do
    travel_to Time.utc(2026, 9, 20, 14)
    CheckSwhidArchivalWorker.jobs.clear
    FetchSwhidWorker.jobs.clear
    @project = Project.create!(url: ORIGIN, science_score: 42, repository: { "clone_url" => ORIGIN }, swhids: {
      "status" => "success", "origin" => ORIGIN,
      "revision" => { "status" => "success", "swhid" => REVISION },
      "directory" => { "status" => "success", "swhid" => DIRECTORY }
    })
    ProjectSwhidScanner.expects(:new).never
  end

  teardown do
    travel_back
    CheckSwhidArchivalWorker.jobs.clear
    FetchSwhidWorker.jobs.clear
  end

  test "sync worker requests missing objects once and follow-up confirms their exact identifiers" do
    known_request(false, false)
    submission = save_request.to_return do
      stored = @project.reload.swhids.fetch("archival")
      assert_equal "submitting", stored["status"]
      assert_equal false, stored.dig("before_request", REVISION, "known")
      { status: 200, body: api_result.to_json }
    end

    @project.fetch_swhids_async
    drain_fetch
    perform_fetch(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "pending", request["status"]
    assert_equal 123, request["id"]
    assert_equal true, request["attribution_eligible"]
    assert_equal [@project.id], CheckSwhidArchivalWorker.jobs.fetch(0)["args"]
    assert_equal 1, CheckSwhidArchivalWorker.jobs.size
    assert_equal 6.hours.from_now.to_f, CheckSwhidArchivalWorker.jobs.first["at"]
    assert_requested submission, times: 1
    assert_equal 0, SwhidArchiver.contribution_counts["total"]

    travel 6.hours
    poll = stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 200, body: api_result(task: "succeeded").to_json)
    known_request(true, true)
    CheckSwhidArchivalWorker.new.perform(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "completed", request["status"]
    assert_equal [REVISION, DIRECTORY].sort, request["confirmed_swhids"].sort
    assert_equal false, @project.swhids.dig("revision", "archive", "first_check", "known")
    assert_equal "archived", @project.swhids.dig("revision", "archive", "status")
    assert_equal({ "total" => 2, "revisions" => 1, "directories" => 1 }, SwhidArchiver.contribution_counts)
    assert_requested poll, times: 1

    travel 8.days
    perform_fetch(@project.id)
    assert_equal request, @project.reload.swhids["archival"]
    assert_requested submission, times: 1
  end

  test "already known objects are never counted as contributions" do
    known_request(true, false)
    save_request.to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)
    assert_equal [DIRECTORY], @project.reload.swhids.dig("archival", "before_request").keys

    travel 6.hours
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 200, body: api_result(task: "succeeded").to_json)
    known_request(true, true)
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_equal [DIRECTORY], @project.reload.swhids.dig("archival", "confirmed_swhids")
    assert_equal({ "total" => 1, "revisions" => 0, "directories" => 1 }, SwhidArchiver.contribution_counts)
  end

  test "a prior repository snapshot identifies a missing version before submission" do
    known_request(false, false)
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(ORIGIN)}/visits/")
      .with(query: { per_page: 100 }).to_return(body: [{ origin: ORIGIN, visit: 1, date: 1.year.ago.iso8601,
        snapshot: "a" * 40, status: "full", type: "git" }].to_json)
    save_request.to_return do
      baseline = @project.reload.swhids.dig("archival", "repository_before_request")
      assert_equal "missing_versions", baseline["classification"]
      assert_equal "pre_submission", baseline["basis"]
      { body: api_result.to_json }
    end

    perform_fetch(@project.id)

    assert_equal "missing_versions", @project.reload.swhids.dig("archival", "repository_before_request", "classification")
    assert_equal "not_found", @project.swhids.dig("revision", "archive", "status")
  end

  test "negative coverage observed before submission stays attached after the repository is archived" do
    known_request(false, false)
    save_request.to_return(body: api_result.to_json)
    perform_fetch(@project.id)
    baseline = @project.reload.swhids.dig("archival", "repository_before_request").deep_dup
    assert_equal "missing_repository", baseline["classification"]

    travel 6.hours
    known_request(true, true)
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(body: api_result(task: "succeeded").to_json)
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_equal [[@project.id, true]], CheckSwhidOriginWorker.jobs.map { |job| job["args"] }
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(ORIGIN)}/visits/")
      .with(query: { per_page: 100 }).to_return(body: [{ origin: ORIGIN, visit: 1, date: 1.hour.ago.iso8601,
        snapshot: "a" * 40, status: "full", type: "git" }].to_json)
    CheckSwhidOriginWorker.perform_one

    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
    assert_equal baseline, @project.swhids.dig("archival", "repository_before_request")
  end

  test "an origin lookup failure permits submission with an unknown classification" do
    known_request(false, false)
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(ORIGIN)}/visits/")
      .with(query: { per_page: 100 }).to_return(status: 503)
    submission = save_request.to_return(body: api_result.to_json)

    perform_fetch(@project.id)

    assert_equal "unknown", @project.reload.swhids.dig("archival", "repository_before_request", "classification")
    assert_requested submission
  end

  test "an origin lookup rate limit postpones submission" do
    known_request(false, false)
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(ORIGIN)}/visits/")
      .with(query: { per_page: 100 }).to_return(status: 429, headers: { "Retry-After" => "3600" })

    perform_fetch(@project.id)

    assert_nil @project.reload.swhids["archival"]
    assert_equal "unknown", @project.swhids.dig("origin_archive", "status")
    assert_operator FetchSwhidWorker.jobs.last.fetch("at"), :>, 1.hour.from_now.to_f
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "known objects and failed coverage checks never submit an archival request" do
    known_request(true, true)
    perform_fetch(@project.id)
    assert_nil @project.reload.swhids["archival"]

    travel 8.days
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 429)
    perform_fetch(@project.id)
    assert_nil @project.reload.swhids["archival"]
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "a cached missing result is rechecked before requesting archival" do
    known_request(false, false)
    @project.check_swhid_archive
    travel 1.day

    known_request(true, true)
    @project.fetch_swhids_async
    drain_fetch

    assert_equal "archived", @project.reload.swhids.dig("revision", "archive", "status")
    assert_nil @project.swhids["archival"]
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "reused requests do not count even when the exact objects become known" do
    stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(body: { REVISION => { known: false }, DIRECTORY => { known: false } }.to_json)
      .then.to_return(body: { REVISION => { known: true }, DIRECTORY => { known: true } }.to_json)
    save_request.to_return(status: 200, body: api_result(task: "succeeded", date: 1.day.ago.iso8601).to_json)

    perform_fetch(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal false, request["attribution_eligible"]
    assert_equal "completed", request["status"]
    assert_equal "archived", @project.swhids.dig("revision", "archive", "status")
    assert_empty request["confirmed_swhids"]
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
  end

  test "a successful new save task does not count objects that are still missing" do
    known_request(false, false)
    save_request.to_return(status: 200, body: api_result(task: "succeeded").to_json)

    perform_fetch(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal true, request["attribution_eligible"]
    assert_empty request["confirmed_swhids"]
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
  end

  test "submission timeouts retain evidence and do not resubmit" do
    known_request(false, false)
    submission = save_request.to_timeout
    perform_fetch(@project.id)

    request = @project.reload.swhids.fetch("archival")
    assert_equal "uncertain", request["status"]
    assert_equal false, request.dig("before_request", REVISION, "known")
    assert request["error"]
    travel 8.days
    perform_fetch(@project.id)
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
    assert_requested submission, times: 1
    assert_empty CheckSwhidArchivalWorker.jobs
  end

  test "failed polling retries the same request and preserves first observations" do
    known_request(false, false)
    submission = save_request.to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)

    travel 6.hours
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 429)
    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_equal "HTTP 429", @project.swhids.dig("archival", "error")
    assert_equal 2, CheckSwhidArchivalWorker.jobs.size
    assert_requested submission, times: 1
  end

  test "rejected requests are retained without polling or contributing" do
    known_request(false, false)
    save_request.to_return(status: 200, body: api_result.merge("save_request_status" => "rejected", "save_task_status" => "not created").to_json)
    perform_fetch(@project.id)

    assert_equal "rejected", @project.reload.swhids.dig("archival", "status")
    assert_empty CheckSwhidArchivalWorker.jobs
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
  end

  test "pending requests expire without submitting again" do
    known_request(false, false)
    submission = save_request.to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)

    travel 31.days
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_equal "expired", @project.reload.swhids.dig("archival", "status")
    assert_requested submission, times: 1
    assert_not_requested :get, "#{SwhidArchiver::ENDPOINT}123/"
  end

  test "an interrupted submission is not repeated" do
    known_request(false, false)
    @project.check_swhid_archive
    SwhidArchiver.new(@project).claim

    travel 6.hours
    perform_fetch(@project.id)

    assert_equal "uncertain", @project.reload.swhids.dig("archival", "status")
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "a failed save task never contributes" do
    known_request(false, false)
    save_request.to_return(status: 200, body: api_result(task: "failed").to_json)

    perform_fetch(@project.id)

    assert_equal "failed", @project.reload.swhids.dig("archival", "status")
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
    assert_empty CheckSwhidArchivalWorker.jobs
  end

  test "invalid submission responses retain evidence without resubmission" do
    known_request(false, false)
    submission = save_request.to_return(status: 200, body: api_result.merge("origin_url" => "https://github.com/another/repo").to_json)

    perform_fetch(@project.id)
    travel 8.days
    perform_fetch(@project.id)

    assert_equal "uncertain", @project.reload.swhids.dig("archival", "status")
    assert_equal "Invalid archival response", @project.swhids.dig("archival", "error")
    assert_requested submission, times: 1
  end

  test "a failed final coverage lookup is retried without losing the save request" do
    known_request(false, false)
    save_request.to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)

    travel 6.hours
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 200, body: api_result(task: "succeeded").to_json)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return(status: 503)
    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_equal 123, @project.swhids.dig("archival", "id")
    assert_equal false, @project.swhids.dig("revision", "archive", "first_check", "known")
    assert_equal 0, SwhidArchiver.contribution_counts["total"]

    travel 6.hours
    known_request(true, true)
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_equal "completed", @project.reload.swhids.dig("archival", "status")
    assert_equal 2, SwhidArchiver.contribution_counts["total"]
  end

  test "archival requests and follow-ups send the optional token without storing it" do
    previous_token = ENV["SWH_API_TOKEN"]
    ENV["SWH_API_TOKEN"] = "test-archival-token"
    known_request(false, false)
    submission = save_request.with(headers: { "Authorization" => "Bearer test-archival-token", "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)" })
      .to_return(status: 200, body: api_result.to_json)
    perform_fetch(@project.id)

    travel 6.hours
    polling = stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").with(headers: { "Authorization" => "Bearer test-archival-token" })
      .to_return(status: 200, body: api_result(task: "succeeded").to_json)
    known_request(true, true)
    CheckSwhidArchivalWorker.new.perform(@project.id)

    assert_requested submission, times: 1
    assert_requested polling, times: 1
    assert_not_includes @project.reload.swhids.to_json, "test-archival-token"
  ensure
    previous_token.nil? ? ENV.delete("SWH_API_TOKEN") : ENV["SWH_API_TOKEN"] = previous_token
  end

  if ENV["SWH_LIVE_TEST"] == "true"
    test "live follow-up reads an existing request and persists exact object coverage" do
      data = @project.swhids.deep_dup
      data["archival"] = {
        "id" => 2364437, "origin" => ORIGIN, "status" => "pending", "attempted_at" => Time.current.iso8601,
        "next_check_at" => Time.current.iso8601, "attribution_eligible" => false,
        "before_request" => { REVISION => { "known" => false, "checked_at" => Time.current.iso8601 } }
      }
      @project.update!(swhids: data)
      WebMock.disable_net_connect!(allow: "archive.softwareheritage.org", allow_localhost: true)

      CheckSwhidArchivalWorker.new.perform(@project.id)

      request = @project.reload.swhids.fetch("archival")
      assert_equal "completed", request["status"], request.inspect
      assert_equal "succeeded", request["save_task_status"]
      assert_equal "archived", @project.swhids.dig("revision", "archive", "status")
      assert_empty request["confirmed_swhids"]
    ensure
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end

  def known_request(revision, directory)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).with(body: [REVISION, DIRECTORY].to_json)
      .to_return(status: 200, body: { REVISION => { known: revision }, DIRECTORY => { known: directory } }.to_json)
  end

  def save_request
    stub_request(:post, SwhidArchiver::ENDPOINT).with(query: { "visit_type" => "git", "origin_url" => ORIGIN })
  end

  def api_result(task: "scheduled", date: Time.utc(2026, 9, 20, 14).iso8601)
    { "id" => 123, "origin_url" => ORIGIN, "visit_type" => "git", "save_request_date" => date,
      "save_request_status" => "accepted", "save_task_status" => task }
  end
end
