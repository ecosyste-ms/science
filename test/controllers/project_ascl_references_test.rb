require "test_helper"
require_relative "../support/ascl_pipeline"

class ProjectAsclReferencesTest < ActionDispatch::IntegrationTest
  include AsclPipeline

  test "imported ASCL identifiers appear in cached page API and distinct homepage counts" do
    project = Project.create!(url: "https://github.com/astropy/photutils", science_score: 42)
    @ascl["1702.002"]["site_list"] = [project.url]
    ascl_catalogue
    sync_ascl(%w[1609.011 1702.002])
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      get project_url(project)
    end
    assert_response :success
    assert_select "[data-role='registry-references'] a[href='https://ascl.net/1609.011']", text: "ASCL: 1609.011"
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('"external_software_records"') }
    assert_equal 1, reads.size
    refute_includes reads.first, '"metadata"'
    get "/api/v1/projects/#{project.id}/external_identifiers"
    assert_response :success
    record = response.parsed_body.find { |entry| entry["identifier"] == "1609.011" }
    assert_equal "ascl", record["scheme"]
    assert_equal "https://ascl.net/1609.011", record["record_url"]
    assert_equal @ascl["1609.011"], record["metadata"]
    assert_equal [["ascl", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /ascl.net/
  end
end
