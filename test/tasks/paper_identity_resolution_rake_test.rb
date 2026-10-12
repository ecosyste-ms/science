require "test_helper"
require "rake"
require "tempfile"

class PaperIdentityResolutionRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:resolve_candidates")
    @previous_env = ENV.to_h.slice("FILE", "OUTPUT", "OPENALEX_API_KEY")
    @input = Tempfile.new(["paper-candidates", ".json"])
    @output = Tempfile.new(["paper-review", ".json"])
    ENV.update("FILE" => @input.path, "OUTPUT" => @output.path, "OPENALEX_API_KEY" => "test-key")
    @title = "BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding"
    @authors = ["Jacob Devlin", "Ming-Wei Chang", "Kenton Lee", "Kristina Toutanova"]
    @candidate = {
      "purl" => "pkg:huggingface/google-bert/bert-base-uncased", "revision" => "86b5e0934494bd15c9632b12f734a8a67f723594",
      "file_url" => "https://huggingface.co/google-bert/bert-base-uncased/resolve/86b5e0934494bd15c9632b12f734a8a67f723594/README.md",
      "identifier_kind" => "arxiv", "identifier" => "1810.04805",
      "occurrences" => [{ "source" => "bibtex", "title" => @title, "line_start" => 278,
        "raw" => "@article{bert, title={#{@title}}, eprint={1810.04805}}" }]
    }
  end

  teardown do
    %w[FILE OUTPUT OPENALEX_API_KEY].each { |key| ENV[key] = @previous_env[key] }
    @input.close!
    @output.close!
  end

  def review(rows)
    File.write(@input.path, { "candidates" => rows }.to_json)
    Rake::Task["papers:resolve_candidates"].reenable
    assert_no_difference ["Paper.count", "ProjectPaper.count", "PackagePaper.count", "Mention.count"] do
      capture_io { Rake::Task["papers:resolve_candidates"].invoke }
    end
    JSON.parse(File.read(@output.path))
  end

  def source(url, title: @title, authors: @authors, doi: nil)
    fields = { "citation_title" => [title], "citation_author" => authors, "citation_doi" => [doi].compact }
    html = fields.flat_map { |name, values| values.map { |value| "<meta name=\"#{name}\" content=\"#{ERB::Util.html_escape(value)}\">" } }.join
    stub_request(:get, url).to_return(status: 200, body: "<html><head>#{html}</head></html>")
  end

  def work(id: "W2963341956", title: @title, authors: @authors)
    { "id" => "https://openalex.org/#{id}", "title" => title,
      "authorships" => authors.map { |name| { "raw_author_name" => name } }, "locations" => [] }
  end

  def lookup(key, response = work, status: 200)
    stub_request(:get, "https://api.openalex.org/works/#{key}")
      .with(query: { "api_key" => "test-key" }).to_return(status: status, body: response.to_json)
  end

  test "retains a conflicting preprint and a separately checked publication with their evidence" do
    source("https://arxiv.org/abs/1810.04805")
    source("https://aclanthology.org/N19-1423/", doi: "10.18653/v1/N19-1423")
    bad_work = work(id: "W2896457183", title: "AI-Assisted Pipeline for Dynamic Generation of Trustworthy Health Supplement Content at Scale")
    lookup("doi:10.48550/arxiv.1810.04805", bad_work)
    lookup("doi:10.18653/v1/n19-1423")
    alternate = @candidate.merge("identifier_kind" => "acl_id", "identifier" => "N19-1423", "derived_from" => "arxiv:1810.04805")

    report = review([@candidate, alternate])

    assert_equal({ "metadata_conflict" => 1, "metadata_agrees" => 1 }, report["summary"])
    assert_equal [@candidate, alternate], report["candidates"].map { |row| row["input"] }
    assert_equal bad_work, report.dig("lookups", "doi:10.48550/arxiv.1810.04805", "work")
    assert_equal true, report["candidates"].first.dig("checks", "authors")
    assert_equal false, report["candidates"].first.dig("checks", "title")
  end

  test "uses current source metadata while retaining the earlier card title" do
    current_title = "C-Pack: Packed Resources For General Chinese Embeddings"
    original = @candidate.merge("identifier" => "2309.07597", "occurrences" => [{ "title" => "C-Pack: Packaged Resources To Advance General Chinese Embedding" }])
    source("https://arxiv.org/abs/2309.07597", title: current_title, authors: ["Xiao, Shitao", "Liu, Zheng"])
    lookup("doi:10.48550/arxiv.2309.07597", work(title: current_title, authors: ["Shitao Xiao", "Zheng Liu"]))

    row = review([original])["candidates"].sole

    assert_equal "metadata_agrees", row["assessment"]
    assert_equal original, row["input"]
    assert_equal [current_title], row["compared_titles"]
  end

  test "does not approve title matches with different authors" do
    source("https://arxiv.org/abs/1810.04805")
    lookup("doi:10.48550/arxiv.1810.04805", work(authors: ["Someone Else"]))
    row = review([@candidate])["candidates"].sole
    assert_equal "metadata_conflict", row["assessment"]
    assert_equal({ "title" => true, "authors" => false }, row["checks"])
  end

  test "deduplicates exact lookups across models and versions without dropping occurrences" do
    source_stub = source("https://arxiv.org/abs/1810.04805")
    work_stub = lookup("doi:10.48550/arxiv.1810.04805")
    other = @candidate.merge("purl" => "pkg:huggingface/example/derived", "identifier" => "1810.04805v2")
    doi = @candidate.merge("identifier_kind" => "doi", "identifier" => "https://doi.org/10.48550/arXiv.1810.04805")
    report = review([@candidate, other, doi])
    assert_equal 3, report["candidates"].size
    assert_equal 1, report["lookups"].size
    assert_equal 1, report["sources"].size
    assert_requested source_stub, times: 1
    assert_requested work_stub, times: 1
  end

  test "supports legacy arxiv IDs and modern ACL identifiers" do
    source("https://arxiv.org/abs/hep-th/9901001")
    source("https://aclanthology.org/2023.emnlp-main.338/", doi: "10.18653/v1/2023.emnlp-main.338")
    lookup("doi:10.48550/arxiv.hep-th/9901001")
    lookup("doi:10.18653/v1/2023.emnlp-main.338")
    report = review([@candidate.merge("identifier" => "hep-th/9901001v2"), @candidate.merge("identifier_kind" => "acl_id", "identifier" => "2023.emnlp-main.338")])
    assert_equal({ "metadata_agrees" => 2 }, report["summary"])
  end

  test "keeps DOI-only matches for review when no source authors were checked" do
    request = lookup("doi:10.18653/v1/n19-1423")
    row = review([@candidate.merge("identifier_kind" => "doi", "identifier" => "DOI:10.18653/v1/N19-1423")])["candidates"].sole
    assert_equal "needs_review", row["assessment"]
    assert_equal({ "title" => true, "authors" => nil }, row["checks"])
    assert_requested request
  end

  test "retains unsupported and invalid references without following their URLs" do
    rows = [@candidate.merge("identifier_kind" => "paper_url", "identifier" => "http://127.0.0.1/private"),
      @candidate.merge("identifier_kind" => "citation_title", "identifier" => @title),
      @candidate.merge("identifier" => "1810.04805?query=bad"),
      @candidate.merge("identifier_kind" => "doi", "identifier" => "10.1234/../private")]
    report = review(rows)
    assert_equal({ "unsupported" => 2, "invalid" => 2 }, report["summary"])
    assert_equal rows, report["candidates"].map { |row| row["input"] }
    assert_empty report["lookups"]
  end

  test "distinguishes missing works from failed or malformed API responses" do
    missing = lookup("W1", {}, status: 404)
    lookup("W2", {}, status: 503)
    lookup("W3", { "results" => [] })
    rows = %w[w1 W2 https://openalex.org/W3 W1].map { |id| @candidate.merge("identifier_kind" => "openalex_id", "identifier" => id) }
    report = review(rows)
    assert_equal({ "not_found" => 2, "error" => 2 }, report["summary"])
    assert_requested missing, times: 1
  end

  test "source failures cannot produce metadata agreement or an invented ACL DOI" do
    stub_request(:get, "https://arxiv.org/abs/1810.04805").to_timeout
    source("https://aclanthology.org/N19-1423/")
    lookup("doi:10.48550/arxiv.1810.04805")
    report = review([@candidate, @candidate.merge("identifier_kind" => "acl_id", "identifier" => "N19-1423")])
    assert_equal({ "needs_review" => 2 }, report["summary"])
    assert_equal 1, report["lookups"].size
    assert report.dig("sources", "arxiv:1810.04805", "error")
  end

  test "incomplete author metadata remains unchecked" do
    source("https://arxiv.org/abs/1810.04805")
    lookup("doi:10.48550/arxiv.1810.04805", work(authors: []))
    row = review([@candidate])["candidates"].sole
    assert_equal "needs_review", row["assessment"]
    assert_nil row.dig("checks", "authors")
  end

  test "decodes UTF-8 source names even when HTML lacks a charset tag" do
    source("https://arxiv.org/abs/1911.01547", title: "On the Measure of Intelligence", authors: ["Chollet, François"])
    lookup("doi:10.48550/arxiv.1911.01547", work(title: "On the Measure of Intelligence", authors: ["François Chollet"]))
    report = review([@candidate.merge("identifier" => "1911.01547")])
    assert_equal "metadata_agrees", report["candidates"].sole["assessment"]
    assert_equal ["Chollet, François"], report.dig("sources", "arxiv:1911.01547", "metadata", "citation_author")
  end

  test "compares parsed BibTeX authors for DOI candidates and retains their provenance" do
    title = "BioGPT: generative pre-trained transformer for biomedical text generation and mining"
    authors = ["Renqian Luo", "Liai Sun", "Yingce Xia", "Tao Qin", "Sheng Zhang", "Hoifung Poon", "Tie-Yan Liu"]
    lookup("doi:10.1093/bib/bbac409", work(title: title, authors: authors))
    row = @candidate.merge("identifier_kind" => "doi", "identifier" => "10.1093/bib/bbac409",
      "occurrences" => [{ "source" => "bibtex", "title" => "{#{title}}",
        "fields" => { "author" => "Luo, Renqian and Sun, Liai and Xia, Yingce and Qin, Tao and Zhang, Sheng and Poon, Hoifung and Liu, Tie-Yan" } }])
    candidate = review([row])["candidates"].sole
    assert_equal "metadata_agrees", candidate["assessment"]
    assert_equal({ "title" => "citation", "authors" => "citation" }, candidate["comparison_sources"])
    assert_equal row, candidate["input"]
  end

  test "does not choose between conflicting BibTeX author lists" do
    lookup("doi:10.18653/v1/n19-1423")
    occurrences = ["Jacob Devlin and Ming-Wei Chang and Kenton Lee and Kristina Toutanova", "Someone Else"].map do |authors|
      { "title" => @title, "fields" => { "author" => authors } }
    end
    row = @candidate.merge("identifier_kind" => "doi", "identifier" => "10.18653/v1/N19-1423", "occurrences" => occurrences)
    candidate = review([row])["candidates"].sole
    assert_equal "needs_review", candidate["assessment"]
    assert_nil candidate.dig("checks", "authors")
  end
end
