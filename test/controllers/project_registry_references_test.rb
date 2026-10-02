require "test_helper"
require_relative "../support/biotools_pipeline"

class ProjectRegistryReferencesTest < ActionDispatch::IntegrationTest
  include BiotoolsPipeline

  setup do
    @project = Project.create!(url: "https://github.com/scverse/scanpy", name: "Scanpy", science_score: 42)
    @project.repository_aliases.create!(url: "https://github.com/theislab/scanpy")
  end

  test "project page and API expose imported registry references without fetching source metadata for the page" do
    biotools_record("scanpy")
    SyncBiotoolsWorker.new.perform(["scanpy"])
    wikidata = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q113089866", status: "ok",
      retrieved_at: Time.current, next_refresh_at: 30.days.from_now)
    @project.project_external_software_records.create!(external_software_record: wikidata,
      relationship: "source_code_repository", match_status: "matched")
    before = @project.reload.attributes
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      get project_url(@project)
    end
    assert_response :success
    assert_select "[data-role='registry-references'] a[href='https://bio.tools/scanpy']", text: "bio.tools: scanpy", count: 1
    assert_select "[data-role='registry-references'] a[href='https://www.wikidata.org/wiki/Q113089866']", text: "Wikidata: Q113089866"
    registry_reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('"external_software_records"') }
    assert_equal 1, registry_reads.size
    assert_not_includes registry_reads.first, '"metadata"'
    assert_not_includes registry_reads.first, '"external_software_records".*'
    get "/api/v1/projects/#{@project.id}/external_identifiers"
    assert_response :success
    record = response.parsed_body.find { |entry| entry["scheme"] == "biotools" }
    assert_equal "https://bio.tools/scanpy", record["record_url"]
    assert_equal @biotools["scanpy"], record["metadata"]
    assert_equal before, @project.reload.attributes
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /bio.tools|wikidata.org/
  end

  test "references exclude ambiguous missing and unchecked records while retaining prior evidence after errors" do
    %w[ok error missing pending].each_with_index do |status, index|
      record = ExternalSoftwareRecord.create!(source: "biotools", identifier: "tool#{index}", status: status,
        retrieved_at: status == "pending" ? nil : Time.current, next_refresh_at: 1.day.from_now)
      @project.project_external_software_records.create!(external_software_record: record,
        relationship: "source_code_repository", match_status: "matched")
    end
    record = ExternalSoftwareRecord.create!(source: "biotools", identifier: "ambiguous", status: "ok",
      retrieved_at: Time.current, next_refresh_at: 1.day.from_now)
    @project.project_external_software_records.create!(external_software_record: record,
      relationship: "source_code_repository", match_status: "ambiguous")
    get project_url(@project)
    assert_response :success
    assert_select "[data-role='registry-references'] a", count: 2
    assert_select "a[href='https://bio.tools/tool0']"
    assert_select "a[href='https://bio.tools/tool1']"
    assert_equal [["biotools", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
  end

  test "projects without registry evidence omit the section and hidden projects remain hidden" do
    get project_url(@project)
    assert_select "[data-role='registry-references']", count: 0
    owner = Owner.create!(host: Host.create!(name: "Registry Host"), login: "hidden", hidden: true)
    @project.update_columns(owner_id: owner.id)
    get project_url(@project)
    assert_response :not_found
  end
end
