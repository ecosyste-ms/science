require "test_helper"
require_relative "../support/model_repository"

class RepositoryCitationImportTest < ActionDispatch::IntegrationTest
  include ModelRepository

  setup do
    build_model_repository
    File.delete(File.join(@repository_directory, "README.md"))
    FileUtils.mkdir_p(File.join(@repository_directory, "inst"))
    @citation = "bibentry(\n  bibtype = \"Article\",\n  title = \"An example method\",\n  doi = \"10.1234/method\"\n)\n"
    File.write(File.join(@repository_directory, "inst/CITATION"), @citation)
    git("-C", @repository_directory, "add", "-A")
    git("-C", @repository_directory, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Add citation")
    @revision = git("-C", @repository_directory, "rev-parse", "HEAD").strip
    @previous_key = ENV["OPENALEX_API_KEY"]
    ENV["OPENALEX_API_KEY"] = "test-key"
    ImportProjectPapersWorker.clear
    @work = { "id" => "https://openalex.org/W123456", "title" => "An example method", "doi" => "https://doi.org/10.1234/method" }
    stub_request(:get, "https://api.openalex.org/works/doi:10.1234/method")
      .with(query: { "api_key" => "test-key" }).to_return(body: @work.to_json)
    RepositoryBriefScan.stubs(:call).returns({ "dependencies" => [], "resources" => { "metadata" => { "citation" => "inst/CITATION" } } })
  end

  teardown do
    ENV["OPENALEX_API_KEY"] = @previous_key
    FileUtils.remove_entry(@repository_directory)
    ImportProjectPapersWorker.clear
  end

  test "ordinary repository scan imports a citation-only paper with commit provenance" do
    RepositoryBriefScan.unstub(:call)
    project = Project.create!(url: "https://github.com/example/research", science_score: 20,
      repository: { "clone_url" => @local_origin, "metadata" => { "files" => { "license" => "LICENSE" } } },
      swhids: { "status" => "success" })

    assert_difference "ImportProjectPapersWorker.jobs.size", 1 do
      RepositoryScanWorker.new.perform(project.id)
    end
    assert_equal "LICENSE", project.reload.repository.dig("metadata", "files", "license")
    assert_equal({ "status" => "success" }, project.swhids)
    assert_citation_import(project, "blob")
    get project_path(project)
    assert_response :success
    assert_includes response.body, "Referenced"
    refute_includes response.body, "Referenced in README"
    assert_select "a[href='#{project.url}/blob/#{@revision}/inst/CITATION']"
  end

  test "model collection imports a citation-only paper for its project and package" do
    registry = PackageRegistry.create!(name: "huggingface.co", ecosystem: "huggingface", purl_type: "huggingface", url: "https://huggingface.co")
    package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model", metadata: { "latest_release_number" => @revision })
    version = package.package_versions.create!(number: @revision, purl: "#{package.purl}@#{@revision}", ecosystems_id: 1, fetched_at: Time.current)
    project = PackageRepository.link!(package)
    project.update!(science_score: 20, swhids: { "status" => "success", "commit" => @revision })
    use_local_model_checkout(project.url)

    report = HuggingFacePackageScanner.collect([version.purl])

    assert_equal "complete", report["versions"].sole["status"]
    assert_equal ["inst/CITATION"], report["versions"].sole["files"].map { |file| file["path"] }
    assert_citation_import(project, "resolve")
    link = package.package_papers.sole
    assert_equal "reference", link.role
    assert_equal project.project_papers.sole.paper, link.paper
    assert_equal "inst/CITATION", link.evidence.sole["file_path"]
  end

  test "failed file reads retain the old content path and provenance" do
    project = Project.create!(url: "https://github.com/example/research", science_score: 20,
      repository: { "clone_url" => @local_origin }, swhids: { "status" => "success" })
    RepositoryScanWorker.new.perform(project.id)
    original = project.reload.repository.dig("metadata", "file_sources", "citation")
    RepositoryBriefScan.stubs(:call).returns({ "dependencies" => [], "resources" => { "metadata" => { "citation" => "../outside" } } })

    ProjectRepositoryScanner.new(project, force_brief: true).scan

    assert_equal @citation, project.reload.citation_file
    assert_equal "inst/CITATION", project.citation_file_name
    assert_equal original, project.repository.dig("metadata", "file_sources", "citation")
    assert_equal "error", project.brief["collected_files"].sole["status"]
  end

  def assert_citation_import(project, action)
    project.reload
    assert_nil project.readme
    assert_equal @citation, project.citation_file
    assert_equal "inst/CITATION", project.citation_file_name
    ImportProjectPapersWorker.perform_one
    link = project.project_papers.sole
    assert_equal "reference", link.role
    evidence = link.evidence.sole
    assert_equal "stored_project_citation", evidence["source"]
    assert_equal "inst/CITATION", evidence["file_path"]
    assert_equal @revision, evidence["revision"]
    assert_equal "#{project.url}/#{action}/#{@revision}/inst/CITATION", evidence["file_url"]
    assert_equal Digest::SHA256.hexdigest(@citation), evidence["file_sha256"]
    assert_equal @citation.lines[3], evidence["occurrences"].sole["raw"]
    assert_no_difference ["Paper.count", "ProjectPaper.count", "PackagePaper.count"] do
      ImportProjectPapersWorker.new.perform(project.id)
    end
    assert_equal [evidence], link.reload.evidence
  end
end
