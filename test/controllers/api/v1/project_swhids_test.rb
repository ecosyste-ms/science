require "test_helper"
require_relative "../../../support/swhid_pipeline"

class Api::V1::ProjectSwhidsTest < ActionDispatch::IntegrationTest
  include SwhidPipeline

  test "API separates former and current origin attempts without treating unchecked URLs as fresh" do
    current = "https://github.com/evidence/current"
    former = "https://github.com/evidence/former"
    project = Project.create!(url: current, science_score: 42, repository: {}, swhids: { "origin" => former })
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    snapshot = { origin: former, visit: 1, date: 1.day.ago.iso8601, snapshot: "a" * 40, status: "full", type: "git" }
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(former)}/visits/")
      .with(query: { per_page: 100 }).to_return(body: [snapshot].to_json)
    failed = snapshot.merge(origin: current, visit: 2, date: 1.hour.ago.iso8601, snapshot: nil, status: "failed")
    older = snapshot.merge(origin: current, date: 1.year.ago.iso8601)
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(current)}/visits/")
      .with(query: { per_page: 100 }).to_return(body: [failed, older].to_json)

    CheckSwhidOriginWorker.perform_async(project.id)
    CheckSwhidOriginWorker.perform_one
    get "/api/v1/projects/#{project.id}/swhids"
    assert_response :success
    initial = response.parsed_body.fetch("origin_archive")
    assert_equal current, initial["repository_url"]
    assert_equal [current, "#{current}.git"], initial["current_origins"]
    assert_equal "other", initial.dig("observations", 0, "origin_role")
    assert_equal former, initial.dig("observations", 0, "latest_attempt", "origin")
    assert_equal false, initial["freshness_complete"]
    assert_includes initial["unchecked_origins"], current

    CheckSwhidOriginWorker.perform_async(project.id, false, true)
    CheckSwhidOriginWorker.perform_one
    get "/api/v1/projects/#{project.id}/swhids"
    assert_response :success
    coverage = response.parsed_body.fetch("origin_archive")
    observation = coverage["observations"].find { |entry| entry["origin"] == current }
    assert_equal true, coverage["freshness_complete"]
    assert_equal "current", observation["origin_role"]
    assert_equal failed.stringify_keys, observation["latest_attempt"]
    assert_equal older.stringify_keys, observation["visit"]
    assert observation["latest_attempt_checked_at"]
    assert_equal initial["observations"].first, coverage["observations"].first
    assert_not_requested :post, /archive\.softwareheritage\.org/
  end

  test "returns saved worker progress and retains observation dates after resuming" do
    project = Project.create!(url: "https://github.com/evidence/progress", science_score: 42,
      repository: { "previous_names" => (1..5).map { |n| "evidence/alias-#{n}" } })
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    origins = SwhidOriginChecker.new(project).origins
    ninth = origins.fetch(8)
    stub_request(:get, "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(ninth)}/visits/")
      .with(query: { per_page: 100 }).to_return(body: [{ origin: ninth, visit: 1, date: 1.day.ago.iso8601,
        snapshot: "a" * 40, status: "full", type: "git" }].to_json)

    CheckSwhidOriginWorker.perform_async(project.id)
    CheckSwhidOriginWorker.perform_one
    get "/api/v1/projects/#{project.id}/swhids"
    assert_response :success
    initial = response.parsed_body.fetch("origin_archive")
    assert_equal false, initial["complete"]
    assert_equal origins.drop(8), initial["unchecked_origins"]
    assert_equal true, initial["observations"].first["lookup_complete"]
    assert_equal true, initial["observations"].first["history_complete"]
    assert initial["observations"].first["attempted_at"]

    travel 2.hours do
      CheckSwhidOriginWorker.perform_async(project.id)
      CheckSwhidOriginWorker.perform_one
      get "/api/v1/projects/#{project.id}/swhids"
    end

    assert_response :success
    saved = response.parsed_body.fetch("origin_archive")
    assert_equal "archived", saved["status"]
    assert_equal initial["observations"].first, saved["observations"].first
    assert_equal origins.drop(9), saved["unchecked_origins"]
    assert_nil saved["retry_at"]
  end

  test "returns persisted typed observations without exposing local paths or scheduling work" do
    project = Project.create!(url: "https://github.com/evidence/test", swhids: {
      "status" => "success", "commit" => "a" * 40, "attempted_at" => "2026-09-23T12:00:00Z",
      "clone_command" => ["git", "clone", "/private/local"],
      "revision" => { "status" => "success", "swhid" => "swh:1:rev:#{'a' * 40}",
        "input" => { "path" => "/private/local" },
        "archive" => { "status" => "not_found", "checked_at" => "2026-09-23T13:00:00Z" } },
      "directory" => { "status" => "success", "swhid" => "swh:1:dir:#{'b' * 40}",
        "archive" => { "status" => "error", "attempted_at" => "2026-09-23T14:00:00Z", "retry_at" => "2026-09-23T15:00:00Z" } },
      "origin_archive" => { "status" => "archived", "checked_at" => "2026-09-23T16:00:00Z",
        "observations" => [{ "origin" => "https://github.com/evidence/old", "status" => "archived",
          "visit" => { "snapshot" => "c" * 40, "date" => "2025-01-01T00:00:00Z", "status" => "full" } }] }
    })
    before = project.reload.attributes
    jobs = Sidekiq::Worker.jobs.deep_dup
    get "/api/v1/projects/#{project.id}/swhids"
    assert_response :success
    body = response.parsed_body
    assert_equal "a" * 40, body.fetch("observed_commit")
    assert_equal %w[revision directory], body.fetch("objects").pluck("type")
    assert_equal "not_found", body.fetch("objects").first.dig("archive", "status")
    assert_equal "error", body.fetch("objects").last.dig("archive", "status")
    assert_equal "2026-09-23T15:00:00Z", body.fetch("objects").last.dig("archive", "retry_at")
    assert_equal "c" * 40, body.dig("origin_archive", "observations", 0, "visit", "snapshot")
    assert_equal false, body.fetch("bytes_verified")
    assert_not_includes response.body, "/private/local"
    assert_equal before, project.reload.attributes
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /archive\.softwareheritage\.org/
  end

  test "unscanned projects are unchecked and hidden projects return not found" do
    project = Project.create!(url: "https://github.com/evidence/unchecked")
    get "/api/v1/projects/#{project.id}/swhids"
    assert_response :success
    assert_equal "unchecked", response.parsed_body.fetch("status")
    assert_equal "unchecked", response.parsed_body.dig("origin_archive", "status")
    assert response.parsed_body.fetch("objects").all? { |object| object.dig("archive", "status") == "unchecked" }
    owner = Owner.create!(host: Host.create!(name: "Evidence GitHub"), login: "hidden", hidden: true)
    project.update_columns(owner_id: owner.id)
    get "/api/v1/projects/#{project.id}/swhids"
    assert_response :not_found
  end
end
