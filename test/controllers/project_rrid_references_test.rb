require "test_helper"
require_relative "../support/rrid_pipeline"

class ProjectRridReferencesTest < ActionDispatch::IntegrationTest
  include RridPipeline

  test "resolved RRIDs use cached references API metadata and distinct source coverage" do
    project = Project.create!(url: "https://github.com/mikelove/deseq2", science_score: 42)
    @rrid["SCR_026162"]["distributions"]["current"] = [{ "uri" => project.url }]
    %w[SCR_015687 SCR_026162].each { |id| rrid_record(id) }
    sync_rrid(%w[SCR_015687 SCR_026162])
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      get project_url(project)
    end
    assert_response :success
    assert_select "[data-role='registry-references'] a[href='https://scicrunch.org/resolver/SCR_015687']", text: "RRID: SCR_015687"
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('"external_software_records"') }
    assert_equal 1, reads.size
    refute_includes reads.first, '"metadata"'
    get "/api/v1/projects/#{project.id}/external_identifiers"
    assert_response :success
    record = response.parsed_body.find { |entry| entry["identifier"] == "SCR_015687" }
    assert_equal "rrid", record["scheme"]
    assert_equal @rrid["SCR_015687"], record["metadata"]
    assert_equal "https://scicrunch.org/resolver/SCR_015687.json", record["evidence"].sole["collection_url"]
    assert_equal [["rrid", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /scicrunch.org/
  end
end
