require "test_helper"
require_relative "../support/jev_records"

class JevDiscoveriesControllerTest < ActionDispatch::IntegrationTest
  include JevRecords
  setup do
    @username, @password = ENV["SIDEKIQ_USERNAME"], ENV["SIDEKIQ_PASSWORD"]
    ENV["SIDEKIQ_USERNAME"], ENV["SIDEKIQ_PASSWORD"] = "reviewer", "review-password"
    @headers = { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("reviewer", "review-password") }
    @candidate = discovery_candidate
  end

  teardown do
    @username ? ENV["SIDEKIQ_USERNAME"] = @username : ENV.delete("SIDEKIQ_USERNAME")
    @password ? ENV["SIDEKIQ_PASSWORD"] = @password : ENV.delete("SIDEKIQ_PASSWORD")
  end

  test "queue and evidence require operator credentials" do
    get jev_discoveries_path
    assert_response :unauthorized
    get jev_discovery_path(@candidate)
    assert_response :unauthorized
    get jev_discoveries_path, headers: @headers
    assert_response :success
    assert_select "h1", "Discovery review"
    get jev_discovery_path(@candidate), headers: @headers
    assert_response :success
    assert_select "textarea[name='jev_discovery[review_notes]']"
  end

  test "review updates shadow judgement alone" do
    project = Project.create!(url: @candidate.repository_url, science_score: 2)
    @candidate.update!(project: project)
    before = project.reload.attributes
    patch jev_discovery_path(@candidate), headers: @headers,
      params: { jev_discovery: { review_state: "research", review_notes: "Source contains a soil solver", science_score: 100 } }
    assert_redirected_to jev_discovery_path(@candidate)
    assert_equal "research", @candidate.reload.review_state
    assert_equal "reviewer", @candidate.reviewed_by
    assert_equal before, project.reload.attributes
  end

  test "invalid review state returns the form" do
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: { review_state: "publish" } }
    assert_response :unprocessable_entity
    assert_equal "unreviewed", @candidate.reload.review_state
  end

  test "review endpoint rejects cross site submissions" do
    JevDiscoveriesController.allow_forgery_protection = true
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: { review_state: "research" } }
    assert_response :unprocessable_entity
    assert_equal "unreviewed", @candidate.reload.review_state
  ensure
    JevDiscoveriesController.allow_forgery_protection = false
  end
end
