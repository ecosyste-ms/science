require "test_helper"
require_relative "../../support/jev/records"

class Jev::DiscoveriesControllerTest < ActionDispatch::IntegrationTest
  include Jev::Records
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

  test "operator records independent review outcomes and filters them without changing model outputs" do
    @candidate.update!(strict_probability: 0.17, implementation_probability: 0.91)
    before = @candidate.attributes.slice("classification", "strict_probability", "implementation_probability", "evidence")
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: {
      review_state: "research", review_purpose: "scientific", review_implementation: "supported",
      review_catalogue_value: "existing_relationship", review_notes: "A scientific variant of an existing project" } }
    assert_redirected_to jev_discovery_path(@candidate)
    assert_equal "scientific", @candidate.reload.review_purpose
    assert_equal "supported", @candidate.review_implementation
    assert_equal "existing_relationship", @candidate.review_catalogue_value
    assert_equal before, @candidate.attributes.slice(*before.keys)
    other = discovery_candidate(run: @candidate.run)
    get jev_discoveries_path(run_id: @candidate.jev_run_id, review_purpose: "scientific", review_catalogue_value: "existing_relationship"), headers: @headers
    assert_response :success
    assert_select "a[href=?]", jev_discovery_path(@candidate)
    assert_select "a[href=?]", jev_discovery_path(other), count: 0
    assert_equal({ "scientific" => 1 }, @candidate.run.statistics[:purpose_reviews])
    get jev_discovery_path(@candidate), headers: @headers
    assert_select "select[name='jev_discovery[review_purpose]'] option[selected][value='scientific']"
    assert_select "select[name='jev_discovery[review_catalogue_value]'] option[selected][value='existing_relationship']"
  end

  test "invalid structured review values are rejected and legacy updates retain existing axes" do
    @candidate.review!(state: "research", notes: "Known source", reviewer: "reviewer", purpose: "scientific", implementation: "supported", catalogue_value: "distinct_candidate")
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: { review_state: "research", review_purpose: "publish" } }
    assert_response :unprocessable_entity
    assert_equal "scientific", @candidate.reload.review_purpose
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: { review_state: "research", review_notes: "Updated note" } }
    assert_redirected_to jev_discovery_path(@candidate)
    assert_equal "supported", @candidate.reload.review_implementation
    assert_equal "distinct_candidate", @candidate.review_catalogue_value
  end

  test "review displays escaped omitted filenames and explains historical missing manifests" do
    @candidate.update!(evidence: @candidate.evidence.merge("skipped_large_files" => 45,
      "skipped_file_paths" => ["analysis.ipynb", "<script>alert(1)</script>.txt"],
      "skipped_file_types" => { ".ipynb" => 40, ".txt" => 5 }, "skipped_file_paths_truncated" => true))
    get jev_discovery_path(@candidate), headers: @headers
    assert_response :success
    assert_select "h2", "Evidence coverage"
    assert_select "li code", "analysis.ipynb"
    assert_select "script", text: "alert(1)", count: 0
    assert_match "Brief counts cover downloaded content", response.body
    assert_match "first 40 omitted filenames", response.body
    @candidate.update!(evidence: @candidate.evidence.except("skipped_file_paths", "skipped_file_types"))
    get jev_discovery_path(@candidate), headers: @headers
    assert_match "Omitted filenames were not recorded", response.body
  end

  test "invalid review state returns the form" do
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: { review_state: "publish" } }
    assert_response :unprocessable_entity
    assert_equal "unreviewed", @candidate.reload.review_state
  end

  test "queue filters repository identities and explains unconfirmed references" do
    project = Project.create!(url: "https://github.com/canonical/model", science_score: 60)
    @candidate.update!(evidence: @candidate.evidence.merge("repository_identity" => {
      "status" => "possible_duplicate", "matches" => [{ "project_id" => project.id, "project_url" => project.url,
        "science_score" => 60, "relation" => "readme_name_match", "confirmed" => false }] }))
    other = discovery_candidate(run: @candidate.run)
    get jev_discoveries_path(run_id: @candidate.jev_run_id, identity: "possible_duplicate"), headers: @headers
    assert_response :success
    assert_select "a[href=?]", jev_discovery_path(@candidate)
    assert_select "a[href=?]", jev_discovery_path(other), count: 0
    get jev_discovery_path(@candidate), headers: @headers
    assert_response :success
    assert_select "a[href=?]", project_path(project)
    assert_match "do not establish that the implementations are identical", response.body
  end

  test "review endpoint rejects cross site submissions" do
    Jev::DiscoveriesController.allow_forgery_protection = true
    patch jev_discovery_path(@candidate), headers: @headers, params: { jev_discovery: { review_state: "research" } }
    assert_response :unprocessable_entity
    assert_equal "unreviewed", @candidate.reload.review_state
  ensure
    Jev::DiscoveriesController.allow_forgery_protection = false
  end

  test "candidate shortlist filters by IDs without admitting projects" do
    other = discovery_candidate(run: @candidate.run)
    get jev_discoveries_path(candidate_ids: @candidate.id.to_s), headers: @headers
    assert_response :success
    assert_select "a[href=?]", jev_discovery_path(@candidate)
    assert_select "a[href=?]", jev_discovery_path(other), count: 0
    assert_empty Catalogue::Admission.all
    ["1,no", "1,", "0", "9223372036854775808", (1..101).to_a.join(",")].each do |ids|
      get jev_discoveries_path(candidate_ids: ids), headers: @headers
      assert_response :bad_request
    end
  end
end
