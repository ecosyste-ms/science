require "test_helper"
require_relative "../support/swhid_pipeline"

class SwhidAuthenticationTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    @previous_token = ENV["SWH_API_TOKEN"]
    ENV["SWH_API_TOKEN"] = "expired-test-token"
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    CheckSwhidArchivalWorker.clear
    @origin = "https://github.com/example/authentication"
    @revision = "swh:1:rev:#{'a' * 40}"
    @project = Project.create!(url: @origin, science_score: 42, repository: {}, swhids: {
      "status" => "success", "origin" => @origin,
      "revision" => { "status" => "success", "swhid" => @revision }
    })
  end

  teardown do
    @previous_token ? ENV["SWH_API_TOKEN"] = @previous_token : ENV.delete("SWH_API_TOKEN")
    CheckSwhidArchivalWorker.clear
  end

  [401, 403].each do |status|
    test "HTTP #{status} escapes the batch worker and is reported immediately" do
      stub_request(:post, SwhidArchiveChecker::ENDPOINT)
        .with(headers: { "Authorization" => "Bearer expired-test-token" })
        .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: {
          exception: "AuthenticationFailed", reason: "Bearer token expired after a long period of inactivity; expired-test-token"
        }.to_json)
      Appsignal.expects(:report_error).with do |error|
        error.is_a?(SwhidApi::AuthenticationError) && error.backtrace.present?
      end
      CheckSwhidBatchWorker.enqueue(@project.id)

      error = assert_raises(SwhidApi::AuthenticationError) { CheckSwhidBatchWorker.perform_one }

      assert_includes error.message, "HTTP #{status}"
      assert_includes error.message, "SWH_API_TOKEN"
      assert_not_includes error.message, ENV.fetch("SWH_API_TOKEN")
      assert_equal [@project.id.to_s], Sidekiq.redis { |redis| redis.call("ZRANGE", CheckSwhidBatchWorker::PENDING_KEY, 0, -1) }
      assert_nil @project.reload.swhids.dig("revision", "archive")
      assert_empty CheckSwhidArchivalWorker.jobs
    end
  end

  test "a disabled account response escapes origin checking" do
    stub_request(:get, %r{archive\.softwareheritage\.org/api/1/origin/.+/visits/})
      .to_return(status: 403, body: "Account is temporarily disabled; contact your administrator or retry later.")
    Appsignal.expects(:report_error).with(is_a(SwhidApi::AuthenticationError))

    assert_raises(SwhidApi::AuthenticationError) { CheckSwhidOriginWorker.new.perform(@project.id) }

    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "a rejected authentication during polling preserves the request and can retry immediately" do
    @project.update!(swhids: @project.swhids.merge("archival" => {
      "id" => 123, "status" => "pending", "origin" => @origin,
      "attempted_at" => 1.day.ago.iso8601, "next_check_at" => 1.hour.ago.iso8601,
      "before_request" => { @revision => { "known" => false, "checked_at" => 1.day.ago.iso8601 } }
    }))
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(status: 403)
    Appsignal.expects(:report_error).with(is_a(SwhidApi::AuthenticationError))

    assert_raises(SwhidApi::AuthenticationError) { CheckSwhidArchivalWorker.new.perform(@project.id) }

    request = @project.reload.swhids.fetch("archival")
    assert_equal 123, request["id"]
    assert_equal "pending", request["status"]
    assert SwhidArchiver.new(@project).due?
    assert_empty CheckSwhidArchivalWorker.jobs
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(body: result.to_json)
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_nil @project.reload.swhids.dig("archival", "error")
    assert_equal 1, CheckSwhidArchivalWorker.jobs.size
  end

  test "a submission rejected for authentication can recover without becoming uncertain" do
    stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(body: { @revision => { known: false } }.to_json)
    stub_request(:post, SwhidArchiver::ENDPOINT).with(query: { origin_url: @origin, visit_type: "git" })
      .to_return(status: 403)
    Appsignal.expects(:report_error).with(is_a(SwhidApi::AuthenticationError))
    @project.check_swhid_archive

    assert_raises(SwhidApi::AuthenticationError) { CheckSwhidArchivalWorker.new.perform(@project.id) }

    assert_equal "authentication_failed", @project.reload.swhids.dig("archival", "status")
    assert_nil @project.swhids.dig("archival", "id")
    assert SwhidArchiver.new(@project).due?
    assert_empty CheckSwhidArchivalWorker.jobs
    stub_request(:post, SwhidArchiver::ENDPOINT).with(query: { origin_url: @origin, visit_type: "git" })
      .to_return(body: result.to_json)
    CheckSwhidArchivalWorker.new.perform(@project.id)
    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_equal 123, @project.swhids.dig("archival", "id")
  end

  def result
    { id: 123, origin_url: @origin, visit_type: "git", save_request_date: Time.current.iso8601,
      save_request_status: "accepted", save_task_status: "scheduled" }
  end
end
