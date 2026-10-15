require "test_helper"
require_relative "../support/mloss_pipeline"

class ProjectMlossReferencesTest < ActionDispatch::IntegrationTest
  include MlossPipeline

  test "imported MLOSS evidence appears on the project and API without source requests or score changes" do
    project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator", science_score: 42)
    mloss_catalogue
    SyncMlossWorker.new.perform(["v27/26-0434"])
    before = project.reload.attributes
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!
    get project_url(project)
    assert_response :success
    assert_select "[data-role='registry-references'] a[href='https://www.jmlr.org/papers/v27/26-0434.html']", text: "JMLR MLOSS: v27/26-0434"
    get "/api/v1/projects/#{project.id}/external_identifiers"
    assert_response :success
    record = response.parsed_body.sole
    assert_equal "mloss", record["scheme"]
    assert_equal "v27/26-0434", record["identifier"]
    assert_equal "https://www.jmlr.org/papers/v27/26-0434.html", record["record_url"]
    assert_equal "A Library for Learning Neural Operators", record["metadata"]["title"]
    assert_equal [project.url], record["metadata"]["code_urls"]
    assert_equal "code_urls", record["evidence"].sole["source_field"]
    assert_equal [["mloss", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
    assert_equal before, project.reload.attributes
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /jmlr.org/
  end
end
