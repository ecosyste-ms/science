require "test_helper"
require "rake"
require "tempfile"

class PaperImportRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:import_candidates")
    @previous_env = ENV.to_h.slice("FILE", "OUTPUT", "OPENALEX_API_KEY")
    @input = Tempfile.new(["paper-import", ".json"])
    @output = Tempfile.new(["paper-results", ".json"])
    ENV.update("FILE" => @input.path, "OUTPUT" => @output.path, "OPENALEX_API_KEY" => "test-key")
    @work = { "id" => "https://openalex.org/W2970771982", "doi" => "https://doi.org/10.18653/v1/D19-1371",
      "title" => "SciBERT: A Pretrained Language Model for Scientific Text", "publication_date" => "2019-11-01",
      "locations" => [{ "landing_page_url" => "https://aclanthology.org/D19-1371/", "pdf_url" => "https://aclanthology.org/D19-1371.pdf" }] }
    @candidate = { "identifier_kind" => "doi", "identifier" => "10.18653/v1/D19-1371",
      "purl" => "pkg:huggingface/allenai/scibert_scivocab_uncased", "revision" => "abc123",
      "occurrences" => [{ "title" => @work["title"], "line_start" => 12, "raw" => "doi:10.18653/v1/D19-1371" }] }
  end

  teardown do
    %w[FILE OUTPUT OPENALEX_API_KEY].each { |key| ENV[key] = @previous_env[key] }
    @input.close!
    @output.close!
  end

  def report
    { "candidates" => [{ "input" => @candidate, "assessment" => "metadata_agrees",
      "checks" => { "title" => true, "authors" => true }, "lookup" => "doi:10.18653/v1/d19-1371" }],
      "lookups" => { "doi:10.18653/v1/d19-1371" => { "status" => "found", "work" => @work } },
      "sources" => { "card" => { "url" => "https://huggingface.co/allenai/scibert_scivocab_uncased" } } }
  end

  def import(data)
    File.write(@input.path, data.to_json)
    Rake::Task["papers:import_candidates"].reenable
    assert_no_difference ["ProjectPaper.count", "PackagePaper.count", "Mention.count"] do
      capture_io { Rake::Task["papers:import_candidates"].invoke }
    end
    JSON.parse(File.read(@output.path))
  end

  def title_candidate
    @candidate.merge("identifier_kind" => "citation_title", "identifier" => @work["title"],
      "occurrences" => [{ "title" => @work["title"], "fields" => { "year" => "2019", "author" => "Alice Smith and Daniel S. Weld" } }])
  end

  def search_results(works, count: works.size)
    stub_request(:get, "https://api.openalex.org/works").with(query: {
      "api_key" => "test-key", "search.title" => @work["title"].scan(/[\p{L}\p{N}]+/).join(" "), "per_page" => "100"
    }).to_return(status: 200, body: { "meta" => { "count" => count }, "results" => works }.to_json)
  end

  def title_work
    @work.merge("publication_year" => 2019, "authorships" => [{ "raw_author_name" => "Alice Smith" }, { "raw_author_name" => "Daniel Weld" }])
  end

  test "imports a unique title author and year match and caches repeated searches" do
    request = search_results([title_work, title_work.merge("id" => "https://openalex.org/W999", "title" => "A different paper")])
    result = import([title_candidate, title_candidate.merge("purl" => "pkg:huggingface/example/other")])
    assert_equal({ "created" => 1, "unchanged" => 1 }, result["import_summary"])
    assert_equal({ "title" => true, "authors" => true, "year" => true }, result["candidates"].first["checks"])
    assert_equal title_candidate, result["candidates"].first["input"]
    assert_equal 2, result["candidates"].first["matches"].size
    assert_requested request, times: 1
  end

  test "does not import ambiguous title matches" do
    search_results([title_work, title_work.merge("id" => "https://openalex.org/W999")])
    assert_no_difference "Paper.count" do
      result = import([title_candidate])
      assert_equal({ "skipped" => 1 }, result["import_summary"])
      assert_match "Multiple", result["candidates"].sole["reason"]
    end
  end

  test "requires the title authors and year to agree" do
    [title_work.merge("publication_year" => 2020), title_work.merge("title" => "Different title"),
      title_work.merge("authorships" => [{ "raw_author_name" => "Someone Else" }]), title_work.except("authorships")].each do |work|
      search_results([work])
      assert_no_difference "Paper.count" do
        assert_equal({ "skipped" => 1 }, import([title_candidate])["import_summary"])
      end
    end
  end

  test "does not search without an unambiguous citation year" do
    candidate = title_candidate
    candidate["occurrences"].sole["fields"].delete("year")
    assert_equal({ "skipped" => 1 }, import([candidate])["import_summary"])
    candidate["occurrences"].sole["fields"]["year"] = "2019"
    candidate["occurrences"] << { "fields" => { "year" => "2020" } }
    assert_equal({ "skipped" => 1 }, import([candidate])["import_summary"])
  end

  test "does not import from incomplete search results" do
    search_results([title_work], count: 101)
    assert_no_difference "Paper.count" do
      assert_equal({ "skipped" => 1 }, import([title_candidate])["import_summary"])
    end
  end

  test "retains title search failures without importing papers" do
    stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("search.title" => @work["title"].scan(/[\p{L}\p{N}]+/).join(" ")))
      .to_return(status: 503)
    assert_no_difference "Paper.count" do
      result = import([title_candidate])
      assert_equal "error", result["candidates"].sole["assessment"]
      assert_equal({ "skipped" => 1 }, result["import_summary"])
    end
  end

  test "does not import when title search has no results or citation authors are absent" do
    search_results([])
    assert_equal({ "skipped" => 1 }, import([title_candidate])["import_summary"])
    search_results([title_work])
    candidate = title_candidate
    candidate["occurrences"].sole["fields"].delete("author")
    assert_equal({ "skipped" => 1 }, import([candidate])["import_summary"])
  end

  test "keeps conflicting middle initials as an author mismatch" do
    work = title_work
    work["authorships"].last["raw_author_name"] = "Daniel J. Weld"
    search_results([work])
    assert_equal({ "skipped" => 1 }, import([title_candidate])["import_summary"])
  end

  test "resolves raw citations and imports exact matches with incomplete metadata" do
    stub_request(:get, "https://api.openalex.org/works/doi:10.18653/v1/d19-1371")
      .with(query: { "api_key" => "test-key" }).to_return(status: 200, body: @work.to_json)
    result = nil
    assert_difference "Paper.count", 1 do
      result = import("candidates" => [@candidate])
    end
    row = result["candidates"].sole
    assert_equal "needs_review", row["assessment"]
    assert_equal @candidate, row["input"]
    paper = Paper.find(row.dig("import", "paper_id"))
    assert_equal @work, paper.openalex_data
    assert_equal "10.18653/v1/d19-1371", paper.doi
    assert_equal Date.new(2019, 11, 1), paper.publication_date.to_date
    assert_equal @work["locations"].sole.values, paper.urls
  end

  test "saved reports need no API key and repeated imports leave papers unchanged" do
    ENV.delete("OPENALEX_API_KEY")
    data = report
    data["candidates"] << data["candidates"].first.deep_dup
    result = import(data)
    assert_equal({ "created" => 1, "unchanged" => 1 }, result["import_summary"])
    assert_equal data["sources"], result["sources"]
    paper = Paper.find(result["candidates"].first.dig("import", "paper_id"))
    before = paper.attributes
    assert_no_difference "Paper.count" do
      assert_equal({ "unchanged" => 2 }, import(data)["import_summary"])
    end
    assert_equal before, paper.reload.attributes
  end

  test "attaches OpenAlex data to an existing DOI paper and preserves URLs" do
    paper = Paper.create!(doi: "10.18653/v1/D19-1371", title: "Old title", urls: ["https://example.org/paper"])
    assert_no_difference "Paper.count" do
      assert_equal({ "updated" => 1 }, import(report)["import_summary"])
    end
    assert_equal @work["id"], paper.reload.openalex_id
    assert_includes paper.urls, "https://example.org/paper"
  end

  test "matches case insensitive short OpenAlex IDs" do
    paper = Paper.create!(openalex_id: "w2970771982")
    assert_no_difference "Paper.count" do
      assert_equal paper.id, import(report)["candidates"].sole.dig("import", "paper_id")
    end
  end

  test "matches legacy HTTP OpenAlex IDs and DOI URLs" do
    paper = Paper.create!(openalex_id: @work["id"].sub("https:", "http:"), doi: @work["doi"])
    assert_no_difference "Paper.count" do
      assert_equal paper.id, import(report)["candidates"].sole.dig("import", "paper_id")
    end
  end

  test "does not overwrite an existing DOI for the same Work" do
    paper = Paper.create!(openalex_id: @work["id"], doi: "10.1234/another")
    before = paper.attributes
    assert_equal({ "error" => 1 }, import(report)["import_summary"])
    assert_equal before, paper.reload.attributes
  end

  test "rejects an output path that would overwrite the input" do
    ENV["OUTPUT"] = @input.path
    File.write(@input.path, report.to_json)
    Rake::Task["papers:import_candidates"].reenable
    assert_no_difference "Paper.count" do
      assert_raises(ArgumentError) { Rake::Task["papers:import_candidates"].invoke }
    end
    assert_equal report, JSON.parse(File.read(@input.path))
  end

  test "skips conflicts and unsupported or unresolved references" do
    data = report
    data["candidates"] = %w[metadata_conflict unsupported not_found error invalid].map do |assessment|
      data["candidates"].first.merge("assessment" => assessment)
    end
    data["candidates"] << { "input" => @candidate, "assessment" => "needs_review" }
    assert_no_difference "Paper.count" do
      assert_equal({ "skipped" => 6 }, import(data)["import_summary"])
    end
  end

  test "reports ambiguous existing papers without merging them" do
    Paper.create!(openalex_id: @work["id"])
    Paper.create!(doi: "10.18653/v1/d19-1371")
    assert_no_difference "Paper.count" do
      assert_equal({ "error" => 1 }, import(report)["import_summary"])
    end
  end

  test "does not overwrite another Work with the same DOI" do
    paper = Paper.create!(openalex_id: "https://openalex.org/W123", doi: "10.18653/v1/d19-1371")
    before = paper.attributes
    assert_equal({ "error" => 1 }, import(report)["import_summary"])
    assert_equal before, paper.reload.attributes
  end

  test "invalid work data is reported without preventing other imports" do
    data = report
    data["candidates"] << data["candidates"].first.merge("lookup" => "W123")
    data["lookups"]["W123"] = { "status" => "found", "work" => { "id" => "bad" } }
    assert_equal({ "created" => 1, "error" => 1 }, import(data)["import_summary"])
  end
end
