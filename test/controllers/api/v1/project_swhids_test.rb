require "test_helper"

class Api::V1::ProjectSwhidsTest < ActionDispatch::IntegrationTest
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
