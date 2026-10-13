require "test_helper"
require "rake"

class ProjectPaperImportTest < ActionDispatch::IntegrationTest
  setup do
    ImportProjectPapersWorker.clear
    @previous_key = ENV["OPENALEX_API_KEY"]
    ENV["OPENALEX_API_KEY"] = "test-key"
    registry = PackageRegistry.create!(name: "huggingface.co", ecosystem: "huggingface", purl_type: "huggingface", url: "https://huggingface.co")
    @package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model", metadata: { "latest_release_number" => "a" * 40 })
    @project = PackageRepository.link!(@package)
    @project.update!(readme: "# Example model\n\nTraining method: https://doi.org/10.1234/method\n", brief: {}, last_synced_at: Time.current)
    @work = { "id" => "https://openalex.org/W123456", "title" => "A training method", "doi" => "https://doi.org/10.1234/method", "publication_date" => "2020-01-01" }
    stub_request(:get, "https://api.openalex.org/works/doi:10.1234/method").with(query: { "api_key" => "test-key" }).to_return(body: @work.to_json)
  end

  teardown do
    ENV["OPENALEX_API_KEY"] = @previous_key
  end

  test "backfill job imports a paper and shows its model citation without implementation claims" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:import_models")
    Rake::Task["papers:import_models"].reenable
    assert_difference "ImportProjectPapersWorker.jobs.size", 1 do
      capture_io { Rake::Task["papers:import_models"].invoke }
    end
    assert_no_difference "Mention.count" do
      ImportProjectPapersWorker.perform_one
    end
    paper = Paper.find_by!(openalex_id: @work["id"])
    project_link = @project.project_papers.sole
    package_link = @package.package_papers.sole
    assert_equal "reference", project_link.role
    assert_equal "reference", package_link.role
    assert_equal paper, project_link.paper
    assert_equal @project.id, project_link.evidence.sole["project_id"]
    assert_includes project_link.evidence.sole["occurrences"].sole["raw"], "10.1234/method"
    assert_empty @package.linked_projects
    assert_equal 20, @project.reload.science_score

    IndexSoftwareSearchWorker.new.perform(@project.id)
    get "/api/v1/software/lookup", params: { q: @package.purl, kind: "purl" }
    assert_response :success
    assert_equal [@project.id], response.parsed_body.fetch("projects").map { |row| row.fetch("project_id") }
    get "/api/v1/projects/#{@project.id}/search_context"
    assert_response :success

    get project_path(@project)
    assert_response :success
    assert_select "#project-research-papers [data-related-paper-id='#{paper.id}']", count: 1
    assert_select "a[href='https://doi.org/10.1234/method']", text: "A training method"
    assert_includes response.body, "Referenced in README"
    assert_includes response.body, "Citation sources"

    attributes = [paper.attributes, project_link.attributes, package_link.attributes]
    assert_no_difference ["Paper.count", "ProjectPaper.count", "PackagePaper.count"] do
      ImportProjectPapersWorker.new.perform(@project.id)
    end
    assert_equal attributes, [paper.reload.attributes, project_link.reload.attributes, package_link.reload.attributes]
  end

  test "regular projects also import and display references" do
    project = Project.create!(url: "https://github.com/example/tool", readme: @project.readme)
    ImportProjectPapersWorker.new.perform(project.id)
    assert_equal "reference", project.project_papers.sole.role
    assert_equal 20, project.reload.science_score
    assert_empty @package.package_papers
    get project_path(project)
    assert_response :success
    assert_select "[data-related-paper-id]", count: 1
  end

  test "backfill links a paper imported earlier and preserves verified implementation roles" do
    paper = Paper.create!(openalex_id: @work["id"], title: @work["title"])
    link = @project.project_papers.create!(paper: paper, evidence: [{ "source" => "verified", "url" => @project.url }])
    assert_no_difference "Paper.count" do
      ImportProjectPapersWorker.new.perform(@project.id)
    end
    assert_equal "implementation", link.reload.role
    assert_equal 2, link.evidence.size
    assert_equal paper, @package.package_papers.sole.paper
  end

  test "API errors cause the background job to retry" do
    stub_request(:get, "https://api.openalex.org/works/doi:10.1234/method").with(query: { "api_key" => "test-key" }).to_return(status: 503)
    assert_raises(RuntimeError) { ImportProjectPapersWorker.new.perform(@project.id) }
    assert_empty @project.project_papers
  end
end
