require "test_helper"
require_relative "../support/software_doi_pipeline"

class ProjectSoftwareDoiReferencesTest < ActionDispatch::IntegrationTest
  include SoftwareDoiPipeline

  test "cached concept and release records share a project reference and retain individual API identities" do
    concept = "10.5281/zenodo.596036"
    release = "10.5281/zenodo.19636730"
    project = doi_project(url: "https://github.com/astropy/photutils", doi: concept)
    [concept, release].each { |id| doi_record(id) }
    sync_dois([concept, release])
    jobs = Sidekiq::Worker.jobs.deep_dup
    WebMock.reset!
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      get project_url(project)
    end
    assert_response :success
    assert_select "[data-role='registry-references'] a", count: 1
    assert_select "[data-role='registry-references'] a[href='https://doi.org/#{concept}']", text: "Zenodo: #{concept}"
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('"external_software_records"') }
    assert_equal 1, reads.size
    refute_includes reads.sole, '"metadata"'
    get "/api/v1/projects/#{project.id}/external_identifiers"
    assert_response :success
    entries = response.parsed_body.index_by { |entry| entry["identifier"] }
    assert_equal [concept, release].sort, entries.keys.sort
    assert_equal "software_concept", entries[concept]["relationship"]
    assert_equal "software_version", entries[release]["relationship"]
    assert_equal concept, entries[release]["concept_identifier"]
    assert_equal "https://doi.org/#{release}", entries[release]["record_url"]
    assert_equal @datacite[release], entries[release]["metadata"]["datacite"]
    assert_equal @zenodo[release], entries[release]["metadata"]["zenodo"]
    assert_equal [["doi", 1]], ProjectExternalSoftwareRecord.scientific_source_counts
    assert_equal jobs, Sidekiq::Worker.jobs
    assert_not_requested :any, /datacite.org|zenodo.org/
  end
end
