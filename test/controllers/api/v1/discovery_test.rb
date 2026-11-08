require "test_helper"
require_relative "../../../support/jev/records"

class Api::V1::DiscoveryTest < ActionDispatch::IntegrationTest
  include Jev::Records

  setup do
    @run = discovery_run
    @candidate = discovery_candidate(run: @run, strict_probability: 0.13, implementation_probability: 0.92,
      classification: "research_candidate", status: "complete", screen_band: "low", control: true,
      control_probability: 0.05, review_purpose: "scientific", review_implementation: "supported",
      review_catalogue_value: "distinct_candidate", review_state: "research",
      reviewed_by: "operator-private", review_notes: "Private operator note", processing_token: "private-token")
  end

  test "public candidate lists retain score zero and included references and hide restricted projects" do
    zero = Project.create!(url: @candidate.repository_url, science_score: 0)
    @candidate.update!(project: zero)
    reference = Project.create!(url: "https://github.com/discovery/reference", science_score: 70)
    second = discovery_candidate(run: @run, project: reference)
    hidden = Project.create!(url: "https://github.com/restricted/example", science_score: 0)
    owner = Owner.create!(host: Host.find_or_create_by!(name: "GitHub"), login: "restricted", hidden: true)
    hidden.update_columns(owner_id: owner.id)
    restricted = discovery_candidate(run: @run, project: hidden)

    get "/api/v1/discovery/candidates", params: { run_id: @run.id }
    assert_response :success
    assert_equal [@candidate.id, second.id], response.parsed_body.pluck("id")
    result = response.parsed_body.first
    assert result.fetch("shadow")
    assert_equal 0.13, result.fetch("strict_probability")
    assert_equal 0.92, result.fetch("implementation_probability")
    assert_equal "scientific", result.fetch("review_purpose")
    assert_equal @run.id, result.fetch("run_id")
    assert_no_private_fields response.body
    get "/api/v1/discovery/candidates/#{restricted.id}"
    assert_response :not_found
  end

  test "candidate queries filter normalized repository URLs project runs controls and review outcomes" do
    discovery_candidate(run: discovery_run)
    project = Project.create!(url: @candidate.repository_url, science_score: 0)
    @candidate.update!(project: project)
    get "/api/v1/discovery/candidates", params: { run_id: @run.id, project_id: project.id,
      repository_url: @candidate.repository_url.upcase + ".git", classification: "research_candidate", screen_band: "low",
      control: true, review_purpose: "scientific", review_implementation: "supported", review_catalogue_value: "distinct_candidate" }
    assert_response :success
    assert_equal [@candidate.id], response.parsed_body.pluck("id")
    get "/api/v1/discovery/candidates", params: { run_id: @run.id, control: false }
    assert_response :success
    assert_empty response.parsed_body
  end

  test "candidate lists are bounded and support pagination links and an ID cursor" do
    second = discovery_candidate(run: @run)
    get "/api/v1/discovery/candidates", params: { run_id: @run.id, per_page: 1 }
    assert_response :success
    assert_equal [@candidate.id], response.parsed_body.pluck("id")
    assert_match 'rel="next"', response.headers.fetch("Link")
    get "/api/v1/discovery/candidates", params: { run_id: @run.id, after_id: @candidate.id, per_page: 1 }
    assert_equal [second.id], response.parsed_body.pluck("id")
    assert_no_match 'rel="next"', response.headers.fetch("Link", "")
  end

  test "details return stored evidence and actual cached evaluation provenance without inference or writes" do
    cached_run = discovery_run
    request = Jev::Request.create!(run: cached_run, digest: "evaluation-#{SecureRandom.hex(8)}", cache_digest: SecureRandom.hex(16),
      stage: "enrich", model: "jev-test", status: "succeeded", question_versions: { "implementation" => "question-fingerprint" },
      request_body: { "state" => { "readme" => "Soil solver", "source_file_paths" => ["solve.py"] },
        "questions" => { "implementation" => "Is this a scientific implementation?" }, "Authorization" => "private-token" },
      response_body: { "answers" => { "implementation" => { "noul" => 0.92 } }, "debug" => "private-token" },
      wire_body: "private-token", input_tokens: 90, output_tokens: 20, cost_usd: "0.00000378", latency_ms: 150)
    @candidate.update!(enrich_request: request, evidence: @candidate.evidence.merge("revision" => "pinned-commit",
      "skipped_file_paths" => ["large.ipynb"], "skipped_large_files" => 1, "internal_secret" => "private-token"))
    before = [@candidate.reload.attributes, @run.reload.attributes, request.reload.attributes]
    Jev::Client.expects(:new).never
    RepositoryCheckout.expects(:new).never
    get "/api/v1/discovery/candidates/#{@candidate.id}"
    assert_response :success
    body = response.parsed_body
    assert_equal ["large.ipynb"], body.fetch("evidence").fetch("skipped_file_paths")
    assert_nil body.fetch("evaluations").fetch("screen")
    evaluation = body.fetch("evaluations").fetch("enrich")
    assert_equal "jev-test", evaluation.fetch("model")
    assert_equal request.id, evaluation.fetch("id")
    assert_equal request.request_body.fetch("state"), evaluation.fetch("input")
    assert_equal request.question_versions, evaluation.fetch("question_versions")
    assert_equal 0.00000378, evaluation.fetch("cost_usd")
    assert_no_private_fields response.body
    assert_equal before, [@candidate.reload.attributes, @run.reload.attributes, request.reload.attributes]
  end

  test "run endpoints expose pinned configuration and aggregate metrics without internal settings" do
    @run.update!(settings: @run.settings.merge("api_key" => "private-token"), last_error: "private-token")
    Jev::Client.expects(:new).never
    get "/api/v1/discovery/runs", params: { per_page: 1 }
    assert_response :success
    assert response.parsed_body.first.fetch("shadow")
    assert_no_private_fields response.body
    get "/api/v1/discovery/runs/#{@run.id}"
    assert_response :success
    body = response.parsed_body
    assert_equal @run.settings.fetch("model"), body.fetch("model")
    assert_equal @run.settings.fetch("question_versions"), body.fetch("question_versions")
    assert_equal 1, body.fetch("statistics").fetch("sampled")
    assert_equal({ "scientific" => 1 }, body.fetch("statistics").fetch("purpose_reviews"))
    assert_no_private_fields response.body
  end

  test "invalid query parameters return JSON errors and missing resources return not found" do
    [{ run_id: "1 OR 1=1" }, { project_id: "-1" }, { after_id: "x" }, { per_page: 101 }, { per_page: "x" },
      { control: "yes" }, { repository_url: "http://localhost/secret" }].each do |params|
      get "/api/v1/discovery/candidates", params: params
      assert_response :bad_request
      assert response.parsed_body.fetch("error").present?
    end
    get "/api/v1/discovery/runs", params: { per_page: 101 }
    assert_response :bad_request
    get "/api/v1/discovery/runs/0"
    assert_response :not_found
    get "/api/v1/discovery/candidates/0"
    assert_response :not_found
  end

  test "discovery endpoints provide no mutation routes" do
    %w[post patch delete].each do |verb|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path("/api/v1/discovery/candidates/#{@candidate.id}", method: verb)
      end
    end
  end

  def assert_no_private_fields(body)
    %w[private-token operator-private reviewed_by review_notes processing_token wire_body api_key internal_secret].each do |value|
      assert_no_match value, body
    end
  end
end
