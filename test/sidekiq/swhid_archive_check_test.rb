require "test_helper"

class SwhidArchiveCheckTest < ActiveSupport::TestCase
  REVISION = "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
  DIRECTORY = "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"

  setup do
    FetchSwhidWorker.jobs.clear
    @api_token = ENV.delete("SWH_API_TOKEN")
    @project = Project.create!(url: "https://github.com/simonehagey/orbdot", science_score: 42,
      repository: { "clone_url" => "https://github.com/simonehagey/orbdot" },
      swhids: {
        "status" => "success",
        "revision" => { "status" => "success", "swhid" => REVISION },
        "directory" => { "status" => "success", "swhid" => DIRECTORY }
      })
    ProjectSwhidScanner.expects(:new).never
  end

  teardown do
    FetchSwhidWorker.jobs.clear
    @api_token.nil? ? ENV.delete("SWH_API_TOKEN") : ENV["SWH_API_TOKEN"] = @api_token
  end

  test "existing identifiers are checked once without recalculating" do
    request = archive_request.with { |request| !request.headers.key?("Authorization") }
      .to_return(status: 200, body: { REVISION => { known: true }, DIRECTORY => { known: false } }.to_json)
    @project.fetch_swhids_async
    assert_equal [[@project.id]], FetchSwhidWorker.jobs.map { |job| job["args"] }

    FetchSwhidWorker.drain
    FetchSwhidWorker.new.perform(@project.id)

    result = @project.reload.swhids
    assert_equal "success", result["status"]
    assert_equal REVISION, result.dig("revision", "swhid")
    assert_equal "archived", result.dig("revision", "archive", "status")
    assert_equal "not_found", result.dig("directory", "archive", "status")
    assert result.dig("directory", "archive", "checked_at")
    assert_nil @project.fetch_swhids_async
    assert_requested request, times: 1
  end

  test "checks refresh after seven days" do
    request = archive_request.to_return(status: 200, body: { REVISION => { known: true }, DIRECTORY => { known: false } }.to_json)
    FetchSwhidWorker.new.perform(@project.id)
    previous_check = @project.reload.swhids.dig("revision", "archive", "checked_at")

    travel 8.days do
      assert @project.fetch_swhids_async
      FetchSwhidWorker.drain
      assert_not_equal previous_check, @project.reload.swhids.dig("revision", "archive", "checked_at")
    end
    assert_requested request, times: 2
  end

  test "rate limits are recorded separately and retried after an hour" do
    request = archive_request.to_return(status: 429)
    FetchSwhidWorker.new.perform(@project.id)

    result = @project.reload.swhids
    assert_equal "success", result["status"]
    %w[revision directory].each do |type|
      assert_equal "error", result.dig(type, "archive", "status")
      assert_equal "HTTP 429", result.dig(type, "archive", "error")
      assert_nil result.dig(type, "archive", "checked_at")
      assert result.dig(type, "archive", "attempted_at")
    end
    assert_nil @project.fetch_swhids_async
    FetchSwhidWorker.new.perform(@project.id)
    assert_requested request, times: 1

    archive_request.to_return(status: 200, body: { REVISION => { known: true }, DIRECTORY => { known: true } }.to_json)
    travel 2.hours do
      assert @project.fetch_swhids_async
      FetchSwhidWorker.drain
      assert_equal "archived", @project.reload.swhids.dig("revision", "archive", "status")
    end
  end

  test "timeouts preserve calculated identifiers" do
    archive_request.to_timeout

    FetchSwhidWorker.new.perform(@project.id)

    result = @project.reload.swhids
    assert_equal "success", result["status"]
    assert_equal REVISION, result.dig("revision", "swhid")
    assert_equal "error", result.dig("revision", "archive", "status")
    assert_operator result.dig("revision", "archive", "error").length, :<=, 500
  end

  test "missing and malformed results are never recorded as not found" do
    request = archive_request.to_return(status: 200, body: { REVISION => { known: true } }.to_json)
    FetchSwhidWorker.new.perform(@project.id)
    assert_equal "archived", @project.reload.swhids.dig("revision", "archive", "status")
    assert_equal "error", @project.swhids.dig("directory", "archive", "status")
    assert_requested request, times: 1

    retry_request = stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .with(body: [DIRECTORY].to_json)
      .to_return(status: 200, body: { DIRECTORY => { known: "false" } }.to_json)
    travel 2.hours do
      FetchSwhidWorker.new.perform(@project.id)
      assert_equal "archived", @project.reload.swhids.dig("revision", "archive", "status")
      assert_equal "error", @project.swhids.dig("directory", "archive", "status")
    end
    assert_requested retry_request, times: 1
  end

  test "invalid JSON is recorded as a check error" do
    archive_request.to_return(status: 200, body: "<html>Service unavailable</html>")

    FetchSwhidWorker.new.perform(@project.id)

    assert_equal "error", @project.reload.swhids.dig("revision", "archive", "status")
    assert_equal "success", @project.swhids["status"]
  end

  test "uses an optional Software Heritage token without storing it" do
    ENV["SWH_API_TOKEN"] = "test-swh-token"
    request = archive_request.with(headers: { "Authorization" => "Bearer test-swh-token" })
      .to_return(status: 200, body: { REVISION => { known: true }, DIRECTORY => { known: true } }.to_json)

    FetchSwhidWorker.new.perform(@project.id)

    assert_requested request, times: 1
    assert_equal "archived", @project.reload.swhids.dig("revision", "archive", "status")
    assert_not_includes @project.swhids.to_json, "test-swh-token"
  end

  if ENV["SWH_LIVE_TEST"] == "true"
    test "live worker checks orbdot against Software Heritage and persists the response" do
      WebMock.disable_net_connect!(allow: "archive.softwareheritage.org", allow_localhost: true)

      FetchSwhidWorker.new.perform(@project.id)

      result = @project.reload.swhids
      assert_equal "archived", result.dig("revision", "archive", "status"), result.inspect
      assert_equal "archived", result.dig("directory", "archive", "status"), result.inspect
      assert result.dig("revision", "archive", "checked_at")
      assert_equal 42, @project.science_score
    ensure
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end

  def archive_request
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).with(body: [REVISION, DIRECTORY].to_json)
  end
end
