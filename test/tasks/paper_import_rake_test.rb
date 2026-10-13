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
