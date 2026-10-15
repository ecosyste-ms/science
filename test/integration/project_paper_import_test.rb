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

  test "comment-only CFF files do not interrupt README paper imports" do
    @project.update!(citation_file: "# Citation information\n# Add the preferred citation here.\n",
      repository: @project.repository.deep_merge("metadata" => { "files" => { "citation" => "CITATION.cff" } }))

    ImportProjectPapersWorker.new.perform(@project.id)

    paper = Paper.find_by!(openalex_id: @work["id"])
    assert_equal paper, @project.project_papers.sole.paper
    assert_equal paper, @package.package_papers.sole.paper
    assert_equal "stored_project_readme", @project.project_papers.sole.evidence.sole["source"]
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
    assert_includes response.body, "Referenced"
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

  test "CFF paper references exclude the software DOI and software references" do
    @project.update!(readme: nil, citation_file: <<~CFF)
      cff-version: 1.2.0
      title: Example software
      doi: 10.1234/software
      preferred-citation:
        type: article
        title: A training method
        doi: 10.1234/method
      references:
        - type: software
          title: A software dependency
          doi: 10.1234/dependency
    CFF
    ImportProjectPapersWorker.new.perform(@project.id)

    evidence = @project.project_papers.sole.evidence.sole
    assert_equal "10.1234/method", evidence["identifier"]
    assert_equal "cff", evidence["occurrences"].sole["source"]
    assert_equal "A training method", evidence["occurrences"].sole["title"]
    occurrence = evidence["occurrences"].sole
    assert_equal @project.citation_file.lines[(occurrence["line_start"] - 1)..(occurrence["line_end"] - 1)].join, occurrence["raw"]
    assert_not_requested :get, "https://api.openalex.org/works/doi:10.1234/software", query: { "api_key" => "test-key" }
    assert_not_requested :get, "https://api.openalex.org/works/doi:10.1234/dependency", query: { "api_key" => "test-key" }
  end

  test "repository-service metadata without a citation path uses the Brief discovery path" do
    project = Project.create!(url: "https://github.com/example/r-package", readme: nil,
      repository: { "metadata" => { "files" => {} } },
      brief: { "resources" => { "metadata" => { "citation" => "inst/CITATION" } } },
      citation_file: 'bibentry(doi = "10.1234/method")')

    ImportProjectPapersWorker.new.perform(project.id)

    assert_equal "inst/CITATION", project.project_papers.sole.evidence.sole["file_path"]
    assert_equal "inst/CITATION", project.citation_file_name
  end

  test "stored content changed after collection does not reuse the scan's revision or parsed entries" do
    @project.update!(readme: nil, citation_file: "https://doi.org/10.1234/method\n",
      repository: @project.repository.deep_merge("metadata" => {
        "files" => { "citation" => "CITATION.bib" },
        "file_sources" => { "citation" => { "path" => "CITATION.bib", "status" => "ok", "sha256" => "outdated", "revision" => "a" * 40 } }
      }),
      brief: { "revision" => "a" * 40, "resources" => { "bibtex" => { "path" => "CITATION.bib",
        "entries" => [{ "key" => "old", "line" => 1, "title" => "Old paper", "doi" => "10.1234/old" }] } } })

    ImportProjectPapersWorker.new.perform(@project.id)

    evidence = @project.project_papers.sole.evidence.sole
    assert_equal "10.1234/method", evidence["identifier"]
    assert_nil evidence["revision"]
    assert_nil evidence["file_url"]
    assert_not_requested :get, "https://api.openalex.org/works/doi:10.1234/old", query: { "api_key" => "test-key" }
  end

  test "PubMed references import through the worker for software and model packages" do
    readme = "# References\n[UniRef publication](http://www.ncbi.nlm.nih.gov/pubmed/17379688).\n"
    paper = { "id" => "https://openalex.org/W2076048958", "title" => "UniRef reference clusters",
      "ids" => { "pmid" => "https://pubmed.ncbi.nlm.nih.gov/17379688" } }
    request = stub_request(:get, "https://api.openalex.org/works/pmid:17379688")
      .with(query: { "api_key" => "test-key" }).to_return(body: paper.to_json)
    software = Project.create!(url: "https://github.com/example/biomedical-tool", readme: readme)
    @project.update!(readme: readme)

    assert_difference "Paper.count", 1 do
      [software, @project].each { |project| ImportProjectPapersWorker.new.perform(project.id) }
    end
    [software.project_papers.sole, @project.project_papers.sole, @package.package_papers.sole].each do |link|
      assert_equal "reference", link.role
      assert_equal paper["id"], link.paper.openalex_id
      assert_nil link.paper.doi
      assert_equal "pmid", link.evidence.sole["identifier_kind"]
      assert_equal "17379688", link.evidence.sole["identifier"]
      assert_equal readme.lines.last, link.evidence.sole["occurrences"].sole["raw"]
    end
    assert_no_difference ["Paper.count", "ProjectPaper.count", "PackagePaper.count"] do
      ImportProjectPapersWorker.new.perform(@project.id)
    end
    assert_requested request, times: 3
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

  test "title search with a long retry delay fails the job without sleeping or creating links" do
    @project.update!(readme: "```bibtex\n@article{mobilenet, title={Searching for MobileNetV3}, author={Howard, Andrew}, year={2019}}\n```\n")
    request = stub_request(:get, "https://api.openalex.org/works")
      .with(query: { "api_key" => "test-key", "search.title" => "Searching for MobileNetV3", "per_page" => "100" })
      .to_return(status: 429, headers: { "Retry-After" => "3600" })
    Faraday::Retry::Middleware.any_instance.expects(:sleep).never

    assert_no_difference ["Paper.count", "ProjectPaper.count", "PackagePaper.count"] do
      error = assert_raises(RuntimeError) { ImportProjectPapersWorker.new.perform(@project.id) }
      assert_equal "Paper import failed for 1 candidates on project #{@project.id}", error.message
    end
    assert_requested request, times: 1
  end
end
