require "test_helper"
require "rake"
require "tempfile"

class PackageCitationCandidatesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:extract_paper_candidates")
    @original_env = ENV.to_h.slice("FILE", "OUTPUT", "OPENALEX_API_KEY")
    @input = Tempfile.new(["package-files", ".json"])
    @output = Tempfile.new(["package-candidates", ".json"])
    ENV.update("FILE" => @input.path, "OUTPUT" => @output.path, "OPENALEX_API_KEY" => "test-key")
    registry = PackageRegistry.create!(name: "huggingface.co", url: "https://huggingface.co",
      ecosystem: "huggingface", purl_type: "huggingface")
    @package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model")
    @version = @package.package_versions.create!(number: "a" * 40,
      purl: "#{@package.purl}@#{'a' * 40}", ecosystems_id: 1, fetched_at: Time.current)
    @base_url = "https://huggingface.co/example/model/resolve/#{@version.number}"
  end

  teardown do
    %w[FILE OUTPUT OPENALEX_API_KEY].each { |key| ENV[key] = @original_env[key] }
    @input.close!
    @output.close!
  end

  def collected_file(path, content)
    { "path" => path, "content" => content, "status" => "ok", "bytes" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content), "url" => "#{@base_url}/#{path}",
      "retrieved_at" => "2026-10-12T12:00:00Z" }
  end

  def collection(files)
    { "versions" => [{ "package_id" => @package.id, "package_version_id" => @version.id,
      "purl" => @version.purl, "revision" => @version.number, "status" => "complete", "files" => files }] }
  end

  def run_task(name)
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  end

  def extract(report)
    File.write(@input.path, report.to_json)
    run_task("packages:extract_paper_candidates")
    JSON.parse(File.read(@output.path))
  end

  test "public tasks collect extract and resolve without approving or importing relationships" do
    readme = <<~MARKDOWN
      # Model
      ## Citation
      ```bibtex
      @article{model,
        title = {A research model},
        author = {Smith, Alice and Jones, Bob},
        doi = {10.1234/model}
      }
      ```
    MARKDOWN
    File.write(@input.path, [@version.purl].to_json)
    stub_request(:get, "https://huggingface.co/api/models/example/model/revision/#{@version.number}")
      .to_return(body: { sha: @version.number, siblings: [{ rfilename: "README.md" }] }.to_json)
    stub_request(:get, "#{@base_url}/README.md").to_return(body: readme)
    work = { "id" => "https://openalex.org/W123", "title" => "A research model",
      "authorships" => [{ "raw_author_name" => "Alice Smith" }, { "raw_author_name" => "Bob Jones" }],
      "locations" => [{ "landing_page_url" => "https://doi.org/10.1234/model" }] }
    request = stub_request(:get, "https://api.openalex.org/works/doi:10.1234/model")
      .with(query: { api_key: "test-key" }).to_return(body: work.to_json)
    attributes = [@package.attributes, @version.attributes]

    assert_no_difference ["Package.count", "PackageVersion.count", "Paper.count", "ProjectPaper.count", "PackagePaper.count", "PackageProject.count", "Mention.count"] do
      report = extract(JSON.parse(run_task("packages:collect_huggingface")))
      assert_equal 1, report["summary"]["candidates"]
      candidate = report["candidates"].sole
      assert_equal @version.purl, candidate["purl"]
      assert_equal @package.purl, candidate["package_purl"]
      assert_equal @version.id, candidate["package_version_id"]
      assert_equal @version.number, candidate["revision"]
      assert_equal "#{@base_url}/README.md", candidate["file_url"]
      assert_equal Digest::SHA256.hexdigest(readme), candidate["file_sha256"]
      assert_nil candidate["relation"]
      occurrence = candidate["occurrences"].find { |item| item["source"] == "bibtex" }
      assert_equal "A research model", occurrence.dig("brief_entry", "title")
      assert_equal "A research model", occurrence["title"]
      assert_equal ["Model", "Citation"], occurrence["section"]
      assert_equal readme.lines[(occurrence["line_start"] - 1)..(occurrence["line_end"] - 1)].join, occurrence["raw"]
      assert_equal "README.md", report["versions"].sole.dig("brief", "resources", "readme_bibtex", "path")

      File.write(@input.path, report.to_json)
      run_task("papers:resolve_candidates")
      resolved = JSON.parse(File.read(@output.path))
      assert_equal "metadata_agrees", resolved["candidates"].sole["assessment"]
      assert_equal candidate, resolved["candidates"].sole["input"]
      assert_equal work, resolved.dig("lookups", "doi:10.1234/model", "work")
    end
    assert_equal attributes, [@package.reload.attributes, @version.reload.attributes]
    assert_requested request, times: 1
  end

  test "retains archive prefixes citation files macros and unsupported identifiers" do
    readme = <<~MARKDOWN
      # Model
      ```bibtex
      @string{prefix = "Scientific "}
      @article{model,
        title = prefix # "{Model}",
        eprint = {2403.18421v2},
        archivePrefix = {arXiv}
      }
      ```
      ## Evaluation
      https://openreview.net/forum?id=AbCd
      https://api.semanticscholar.org/CorpusID:254018137
    MARKDOWN
    bib = "@article{other, title={Other paper}, doi={10.1234/other}, author={Smith, Alice}}\n"

    report = extract(collection([collected_file("README.md", readme), collected_file("CITATION.bib", bib)]))

    arxiv = report["candidates"].find { |row| row["identifier"] == "2403.18421" }
    assert_equal "arxiv", arxiv["identifier_kind"]
    assert_equal "arXiv", arxiv["occurrences"].last.dig("fields", "archiveprefix")
    citation = report["candidates"].find { |row| row["identifier"] == "10.1234/other" }
    assert_equal "CITATION.bib", citation["file_path"]
    assert_equal "Other paper", citation["occurrences"].last["title"]
    assert_includes report["candidates"].map { |row| row["identifier_kind"] }, "openreview_id"
    assert_includes report["candidates"].map { |row| row["identifier_kind"] }, "semantic_scholar_corpus_id"
    assert report["candidates"].all? { |row| row["relation"].nil? }
  end

  test "keeps valid DOI punctuation and excludes identifiers embedded in publisher PDF paths" do
    text = <<~MARKDOWN
      [Paper](https://doi.org/10.1000/abc(def)).
      https://academic.oup.com/bib/article-pdf/23/6/bbac409/47144271/bbac409.pdf
      https://example.org/articles/10.1234/paper/full.pdf
      https://arxiv.org.evil.invalid/abs/2403.18421
      https://openreview.net.evil.invalid/forum?id=bad
      https://arxiv.org/pdf/hep-th/9901001v2.pdf
      https://www.biorxiv.org/content/10.1101/2022.07.20.500902v2.full.pdf
      https://doi.org/10.1234/keepv2
      https://www.aclweb.org/anthology/D19-1371/
    MARKDOWN
    rows = extract(collection([collected_file("README.md", text)]))["candidates"]

    assert_equal %w[10.1000/abc(def) 10.1101/2022.07.20.500902 10.1234/keepv2], rows.select { |row| row["identifier_kind"] == "doi" }.map { |row| row["identifier"] }
    assert_includes rows.map { |row| row["identifier"] }, "hep-th/9901001"
    assert_includes rows.map { |row| row["identifier"] }, "D19-1371"
    assert_equal 2, rows.count { |row| row["identifier_kind"] == "paper_url" }
    assert_not_includes rows.map { |row| row["identifier"] }, "2403.18421"
    assert_not_includes rows.map { |row| row["identifier"] }, "bad"
  end

  test "retains malformed BibTeX diagnostics and explicit paper links" do
    text = "Paper: https://arxiv.org/abs/2403.18421\n```bibtex\n@article{broken, title={unfinished\n```\n"
    report = extract(collection([collected_file("README.md", text)]))

    assert_includes report["candidates"].map { |row| row["identifier"] }, "2403.18421"
    assert_not_empty report["versions"].sole["diagnostics"]
  end

  test "empty citation templates produce no candidates and title-only references stay reviewable" do
    text = "```bibtex\n@article{empty, title={}, author={}}\n@article{title, title={A paper without an identifier}}\n```\n"
    report = extract(collection([collected_file("README.md", text)]))

    assert_equal ["citation_title"], report["candidates"].map { |row| row["identifier_kind"] }
    assert_equal "A paper without an identifier", report["candidates"].sole["identifier"]
    assert_nil report["candidates"].sole["relation"]
  end

  test "preserves failed collection outcomes and ignores configuration links" do
    report = collection([{ "path" => "README.md", "status" => "gated", "http_status" => 401 },
      collected_file("config.json", '{"url":"https://doi.org/10.1234/config"}')])
    report["versions"].first["status"] = "partial"

    result = extract(report)

    assert_empty result["candidates"]
    assert_equal "partial", result["versions"].sole["status"]
    assert_equal "gated", result["versions"].sole["files"].first["status"]
  end

  test "validates version identities checksums paths and bounds before running Brief" do
    valid = collection([collected_file("README.md", "# Model")])
    invalid_rows = [
      valid["versions"].first.merge("purl" => @package.purl),
      valid["versions"].first.merge("revision" => "b" * 40),
      valid["versions"].first.merge("files" => [collected_file("../README.md", "bad")]),
      valid["versions"].first.merge("files" => [collected_file("README.md", "# Model").merge("content" => "changed")])
    ]
    RepositoryCommand.any_instance.expects(:run).never
    invalid_rows.each do |row|
      assert_raises(ArgumentError) { extract({ "versions" => [valid["versions"].first, row] }) }
    end
    assert_raises(ArgumentError) { extract({ "versions" => [] }) }
    assert_raises(ArgumentError) { extract({ "versions" => Array.new(26, valid["versions"].first) }) }
    ENV["OUTPUT"] = @input.path
    assert_raises(ArgumentError) { extract(valid) }
  end

  test "reports Brief failures without implying that no citations exist" do
    RepositoryCommand.any_instance.expects(:run).raises(RepositoryCommand::Error, "command timed out")

    result = extract(collection([collected_file("README.md", "# Model")]))

    assert_equal "command timed out", result["versions"].sole["extraction_error"]
    assert_equal 1, result["summary"]["extraction_errors"]
    assert_empty result["candidates"]
  end
end
