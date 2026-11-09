require "test_helper"
require_relative "../../support/jev/records"

class Catalogue::AdmissionsControllerTest < ActionDispatch::IntegrationTest
  include Jev::Records

  setup do
    @username, @password = ENV["SIDEKIQ_USERNAME"], ENV["SIDEKIQ_PASSWORD"]
    ENV["SIDEKIQ_USERNAME"], ENV["SIDEKIQ_PASSWORD"] = "operator", "review-password"
    @headers = { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("operator", "review-password") }
    @project = Project.create!(url: "https://github.com/research/reviewed-solver", name: "Reviewed Solver", science_score: 0,
      last_synced_at: 2.days.ago)
    @candidate = discovery_candidate(project: @project)
    SyncProjectWorker.clear
    IndexSoftwareSearchWorker.clear
  end

  teardown do
    @username ? ENV["SIDEKIQ_USERNAME"] = @username : ENV.delete("SIDEKIQ_USERNAME")
    @password ? ENV["SIDEKIQ_PASSWORD"] = @password : ENV.delete("SIDEKIQ_PASSWORD")
    SyncProjectWorker.clear
    IndexSoftwareSearchWorker.clear
  end

  def submit(decision = "accepted", reason = "Source implements a numerical research solver")
    post project_admission_path(@project), headers: @headers, params: { catalogue_admission: {
      decision: decision, reason: reason, source_discovery_id: @candidate.id, science_score: 100, reviewed_by: "forged" } }
  end

  test "catalogue decisions require operator authentication and are not written by GET" do
    get catalogue_admissions_path
    assert_response :unauthorized
    post project_admission_path(@project), params: { catalogue_admission: { decision: "accepted", reason: "Untrusted" } }
    assert_response :unauthorized
    get project_admission_path(@project), headers: @headers
    assert_response :success
    assert_select "select[name='catalogue_admission[decision]'] option[selected][value='accepted']", count: 0
    assert_empty Catalogue::Admission.all
  end

  test "operator approval persists inclusion and is visible in public catalogue and API" do
    submit
    assert_redirected_to project_admission_path(@project)
    admission = @project.reload.catalogue_admission
    assert_equal "operator", admission.reviewed_by
    assert_equal @candidate.id, admission.source_discovery_id
    assert_equal 0, @project.science_score
    assert_equal "unreviewed", @candidate.reload.review_state
    get projects_path
    assert_response :success
    assert_select "a[href=?]", project_path(@project)
    get api_v1_project_path(@project)
    assert_response :success
    assert_equal true, response.parsed_body["catalogue_included"]
    assert_equal "accepted", response.parsed_body.dig("catalogue_admission", "decision")
    refute response.parsed_body.fetch("catalogue_admission").key?("reviewed_by")
    get project_path(@project)
    assert_response :success
    assert_match "Operator-approved catalogue entry", response.body
    get catalogue_admissions_path, headers: @headers
    assert_response :success
    assert_match "1 current approvals", response.body
  end

  test "withdrawal removes the zero-score exception and retains both reasons" do
    submit
    patch project_admission_path(@project), headers: @headers, params: { catalogue_admission: { decision: "deferred", reason: "Reconcile repository identity" } }
    assert_redirected_to project_admission_path(@project)
    refute Project.in_catalogue.exists?(@project.id)
    assert_equal "Source implements a numerical research solver", @project.reload.catalogue_admission.history.first["reason"]
    get projects_path
    assert_select "a[href=?]", project_path(@project), count: 0
  end

  test "missing reason returns the form without admission" do
    submit("accepted", " ")
    assert_response :unprocessable_entity
    assert_empty Catalogue::Admission.all
    refute Project.in_catalogue.exists?(@project.id)
  end

  test "an invalid amendment displays the stored decision and leaves its history unchanged" do
    submit
    patch project_admission_path(@project), headers: @headers, params: { catalogue_admission: { decision: "rejected", reason: " " } }
    assert_response :unprocessable_entity
    assert_match "Last decision: accepted", response.body
    admission = @project.reload.catalogue_admission
    assert_equal "accepted", admission.decision
    assert_empty admission.history
  end

  test "admitted zero-score software can be indexed and found without inflating its score" do
    submit
    IndexSoftwareSearchWorker.new.perform(@project.id)
    results = SoftwareSearch.results(query: @project.url, kind: "repository_url")
    assert_equal [@project.id], results[:projects].map { |row| row[:project_id] }
    get search_projects_path(q: "Reviewed Solver")
    assert_response :success
    assert_select "a[href=?]", project_path(@project)
    assert_equal 0, @project.reload.science_score
  end

  test "public API filters operator decisions independently of Science Score" do
    submit
    other = Project.create!(url: "https://github.com/research/automatic", science_score: 60, last_synced_at: Time.current)
    get api_v1_projects_path(admission: "Accepted")
    assert_response :success
    assert_equal [@project.id], response.parsed_body.pluck("id")
    get api_v1_projects_path(admission: "automatic")
    assert_response :bad_request
    get api_v1_project_path(other)
    assert_response :success
    assert response.parsed_body["catalogue_included"]
    assert_nil response.parsed_body["catalogue_admission"]
    patch project_admission_path(@project), headers: @headers,
      params: { catalogue_admission: { decision: "deferred", reason: "Check canonical identity" } }
    get api_v1_projects_path(admission: "accepted")
    assert_empty response.parsed_body
    get api_v1_projects_path(admission: "deferred")
    assert_equal [@project.id], response.parsed_body.pluck("id")
  end

  test "search seed and context APIs include an admitted project without repository metadata" do
    submit
    get search_seeds_api_v1_projects_path
    assert_response :success
    assert_equal [@project.id], response.parsed_body.pluck("project_id")
    get search_context_api_v1_project_path(@project)
    assert_response :success
    assert_equal @project.id, response.parsed_body["project_id"]
  end

  test "run statistics count additions once and preserve their original source on amendment" do
    submit
    run = @candidate.run
    assert_equal({ "accepted" => 1 }, run.statistics[:catalogue_decisions])
    assert_equal 1, run.statistics[:catalogue_additions]
    get jev_discoveries_path(run_id: run.id), headers: @headers
    assert_response :success
    assert_match "Catalogue additions with current operator approval: 1", response.body
    next_candidate = discovery_candidate(project: @project)
    patch project_admission_path(@project), headers: @headers, params: { catalogue_admission: {
      decision: "accepted", reason: "Additional source evidence", source_discovery_id: next_candidate.id } }
    assert_redirected_to project_admission_path(@project)
    assert_equal 1, run.statistics[:catalogue_additions]
    assert_equal 0, next_candidate.run.statistics[:catalogue_additions]
    assert_equal({ "accepted" => 1 }, next_candidate.run.statistics[:catalogue_decisions])
    @project.update!(science_score: 50)
    submit("rejected", "Normal score rules now qualify this project")
    assert_equal 0, run.statistics[:catalogue_additions]
    assert @project.reload.catalogued?
  end

  test "model answers and source retries cannot grant or remove operator admission" do
    @candidate.update!(status: "complete", strict_probability: 0.99, implementation_probability: 0.99,
      classification: "research_candidate", enrichment_error: "Incomplete checkout")
    refute @project.reload.catalogued?
    submit
    @candidate.retry_evidence!
    assert_equal "pending_enrich", @candidate.reload.status
    assert @project.reload.catalogued?
    assert_equal "accepted", @project.catalogue_admission.decision
    @candidate.run.reevaluate!
    assert_equal "pending_screen", @candidate.reload.status
    assert @project.reload.catalogued?
    assert_equal "accepted", @project.catalogue_admission.decision
    assert_equal 0, @project.science_score
  end

  test "operator decisions refresh author evidence counts when membership changes" do
    author = Author.create!(canonical_key: "email:solver@example.edu", display_name: "Solver Author")
    ProjectAuthor.create!(project: @project, author: author, source: "citation_cff", authorship_kind: "software",
      author_kind: "person", position: 1, display_name: author.display_name, source_path: "authors[0]", source_digest: "solver-citation")
    AuthorPublicEvidenceCounter.refresh!([author.id])
    assert_equal 0, author.reload.public_evidence_count
    submit
    assert_redirected_to project_admission_path(@project)
    assert_equal 1, author.reload.public_evidence_count
    submit("deferred", "Check identity")
    assert_redirected_to project_admission_path(@project)
    assert_equal 0, author.reload.public_evidence_count
  end

  test "OpenAPI describes public admission fields and filtering without private audit fields" do
    schema = YAML.safe_load_file(Rails.root.join("openapi/api/v1/openapi.yaml"))
    parameters = schema.dig("paths", "/projects", "get", "parameters")
    assert_equal Catalogue::Admission::DECISIONS.keys, parameters.find { |item| item["name"] == "admission" }.dig("schema", "enum")
    fields = schema.dig("components", "schemas", "CatalogueAdmission", "properties")
    submit
    get api_v1_project_path(@project)
    assert_equal fields.keys.sort, response.parsed_body.fetch("catalogue_admission").keys.sort
    refute fields.key?("reviewed_by")
    refute fields.key?("history")
  end

  test "hidden-owner projects cannot be admitted through the operator route" do
    host = Host.create!(name: "GitHub", url: "https://github.com", kind: "github")
    owner = Owner.create!(host: host, login: "hidden", hidden: true)
    @project.update_columns(owner_id: owner.id)
    submit
    assert_response :not_found
    assert_empty Catalogue::Admission.all
  end

  test "admission endpoint rejects cross-site submissions" do
    Catalogue::AdmissionsController.allow_forgery_protection = true
    submit
    assert_response :unprocessable_entity
    assert_empty Catalogue::Admission.all
  ensure
    Catalogue::AdmissionsController.allow_forgery_protection = false
  end
end
