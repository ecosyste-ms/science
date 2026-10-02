require "test_helper"
require_relative "../support/swmath_pipeline"

class ProjectSwmathReferencesTest < ActionDispatch::IntegrationTest
  include SwmathPipeline

  test "worker imported references use cached metadata in project page API and distinct source counts" do
    project = Project.create!(url: "https://github.com/numpy/numpy", science_score: 42)
    @swmath["825"]["source_code"] = project.url
    %w[6294 825].each { |id| swmath_record(id) }
    sync_swmath(%w[6294 825])
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      get project_url(project)
    end
    assert_response :success
    assert_select "[data-role='registry-references'] a[href='https://zbmath.org/software/6294']", text: "swMATH: 6294"
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('"external_software_records"') }
    assert_equal 1, reads.size
    refute_includes reads.first, '"metadata"'
    get "/api/v1/projects/#{project.id}/external_identifiers"
    assert_response :success
    record = response.parsed_body.find { |entry| entry["identifier"] == "6294" }
    assert_equal "swmath", record["scheme"]
    assert_equal "https://zbmath.org/software/6294", record["record_url"]
    assert_equal @swmath["6294"], record["metadata"]
    assert_equal "CC-BY-SA-4.0", record["evidence"].sole["source_license"]
    assert_equal [["swmath", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /api.zbmath.org/
  end
end
