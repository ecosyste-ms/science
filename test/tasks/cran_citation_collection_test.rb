require "test_helper"
require "rake"
require "tmpdir"

class CranCitationCollectionTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:collect_cran")
    @previous_env = ENV.to_h.slice("FILE", "OUTPUT", "OPENALEX_API_KEY")
    @directory = Dir.mktmpdir("cran-citations-")
    registry = PackageRegistry.create!(name: "CRAN.R-project.org", url: "https://cran.r-project.org", ecosystem: "cran", purl_type: "cran")
    @package = registry.packages.create!(name: "example", purl: "pkg:cran/example")
    @version = @package.package_versions.create!(number: "1.0", purl: "pkg:cran/example@1.0", ecosystems_id: 1, fetched_at: Time.current)
    @base = "https://cran.r-project.org/web/packages/example"
    @description = "Package: example\nVersion: 1.0\nTitle: An example package\n"
    @description_request = stub_request(:get, "#{@base}/DESCRIPTION").to_return(body: @description)
    @html = <<~HTML
      <!DOCTYPE html>
      <html><body><p>Corresponding BibTeX entries:</p>
      <pre>
        @Article{,
          title = {A method &amp; its applications},
          author = {Example, Alice},
          year = {2024},
          doi = {10.1234/method}
        }
      </pre>
      <pre>
        @Article{,
          title = {Another research method},
          author = {Other, Bob},
          year = {2023}
        }
      </pre>
      </body></html>
    HTML
    @citation_request = stub_request(:get, "#{@base}/citation.html").to_return(body: @html)
  end

  teardown do
    %w[FILE OUTPUT OPENALEX_API_KEY].each { |key| ENV[key] = @previous_env[key] }
    FileUtils.remove_entry(@directory)
  end

  def run_task(task, input)
    ENV["FILE"] = File.join(@directory, "input.json")
    ENV["OUTPUT"] = File.join(@directory, "output.json")
    File.write(ENV["FILE"], JSON.generate(input))
    capture_io { Rake::Task[task].execute }
    JSON.parse(File.read(ENV["OUTPUT"]))
  end

  test "public tasks collect and extract keyless CRAN citations with original HTML evidence" do
    RepositoryBriefScan.expects(:call).never
    assert_no_difference ["Package.count", "PackageVersion.count", "Paper.count", "PackagePaper.count", "ProjectPaper.count"] do
      collected = run_task("packages:collect_cran", [@version.purl])
      row = collected["versions"].sole
      assert_equal "complete", row["status"]
      assert_equal @html, row["files"].sole["content"]
      assert_equal Digest::SHA256.hexdigest(@description), row.dig("file_list_source", "sha256")
      assert_equal Digest::SHA256.hexdigest(@html), row["files"].sole["sha256"]
      assert_equal "1.0", row["published_version"]

      report = run_task("packages:extract_paper_candidates", collected)
      assert_equal 2, report["candidates"].size
      first, second = report["candidates"]
      assert_equal "10.1234/method", first["identifier"]
      assert_equal "citation_title", second["identifier_kind"]
      assert_equal "Another research method", second["identifier"]
      details = first["occurrences"].find { |item| item["title"] }
      assert_equal "A method & its applications", details["title"]
      assert_equal "Example, Alice", details.dig("fields", "author")
      [first, second].each do |candidate|
        assert_equal @version.purl, candidate["purl"]
        assert_equal "#{@base}/citation.html", candidate["file_url"]
        assert_equal "citation.html", candidate["file_path"]
        candidate["occurrences"].each do |item|
          assert_equal "html_bibtex", item["source"]
          assert_equal @html.lines[(item["line_start"] - 1)..(item["line_end"] - 1)].join, item["raw"]
          refute_includes item["raw"], "science-keyless-"
        end
      end
      assert_empty report["versions"].sole["diagnostics"]
    end
    assert_requested @description_request, times: 2
    assert_requested @citation_request, times: 1
  end

  test "an old package version is not attributed the current citation page" do
    stub_request(:get, "#{@base}/DESCRIPTION").to_return(body: @description.sub("Version: 1.0", "Version: 2.0"))
    report = run_task("packages:collect_cran", [@version.purl])
    assert_equal "version_mismatch", report["versions"].sole["status"]
    assert_empty report["versions"].sole["files"]
    assert_not_requested @citation_request
  end

  test "collected CRAN citations import through the public task with package and project evidence" do
    ENV["OPENALEX_API_KEY"] = "test-key"
    project = Project.create!(url: "https://github.com/example/research")
    @package.update!(published_by_project: project)
    first = { "id" => "https://openalex.org/W123", "title" => "A method & its applications", "publication_year" => 2024,
      "authorships" => [{ "raw_author_name" => "Alice Example" }] }
    second = { "id" => "https://openalex.org/W456", "title" => "Another research method", "publication_year" => 2023,
      "authorships" => [{ "raw_author_name" => "Bob Other" }] }
    stub_request(:get, "https://api.openalex.org/works/doi:10.1234/method")
      .with(query: { "api_key" => "test-key" }).to_return(body: first.to_json)
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: { "api_key" => "test-key", "search.title" => "Another research method", "per_page" => "100" })
      .to_return(body: { "meta" => { "count" => 1 }, "results" => [second] }.to_json)

    collection = run_task("packages:collect_cran", [@version.purl])
    candidates = run_task("packages:extract_paper_candidates", collection)
    assert_difference ["Paper.count", "PackagePaper.count", "ProjectPaper.count"], 2 do
      report = run_task("papers:import_candidates", candidates)
      assert_equal ["metadata_agrees"], report["candidates"].map { |row| row["assessment"] }.uniq
    end
    (@package.package_papers + project.project_papers).each do |link|
      assert_equal "reference", link.role
      assert_equal @version.purl, link.evidence.sole["purl"]
      assert_equal "#{@base}/citation.html", link.evidence.sole["file_url"]
      assert_equal "1.0", link.evidence.sole.dig("file_list_source", "revision")
    end
    assert_no_difference ["Paper.count", "PackagePaper.count", "ProjectPaper.count"] do
      run_task("papers:import_candidates", candidates)
    end
  end

  test "a release changing during collection does not produce attributed files" do
    stub_request(:get, "#{@base}/DESCRIPTION").to_return(body: @description)
      .then.to_return(body: @description.sub("Version: 1.0", "Version: 2.0"))
    result = run_task("packages:collect_cran", [@version.purl])["versions"].sole
    assert_equal "error", result["status"]
    assert_includes result["error"], "changed during collection"
    assert_empty result["files"]
  end

  test "collection rejects missing versions and oversized batches before making requests" do
    assert_raises(ArgumentError) { run_task("packages:collect_cran", [@package.purl]) }
    assert_raises(ArgumentError) { run_task("packages:collect_cran", [@version.purl] * 26) }
    assert_not_requested @description_request
  end

  test "HTTP failures redirects missing citations and large responses are reported without files" do
    [{ status: 429 }, { status: 302, headers: { "Location" => "https://example.org/other" } },
     { body: "<html><body>No citations</body></html>" }, { body: "x" * (1.megabyte + 1) }].each do |response|
      stub_request(:get, "#{@base}/citation.html").to_return(response)
      result = run_task("packages:collect_cran", [@version.purl])["versions"].sole
      assert_equal "error", result["status"]
      assert_empty result["files"]
    end
    assert_not_requested :get, "https://example.org/other"
  end
end
