require "test_helper"
require "rake"
require "tempfile"
require_relative "../support/mloss_pipeline"

class JournalPublicationImportTest < ActiveSupport::TestCase
  include MlossPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:import_candidates")
    @project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator")
    @article_id = "v27/26-0434"
    @article_url = MlossClient.article_url(@article_id)
    @work = { "id" => "https://openalex.org/W12345678", "doi" => nil,
      "title" => "A Library for Learning Neural Operators", "publication_date" => "2026-10-01",
      "locations" => [{ "landing_page_url" => @article_url,
        "pdf_url" => "https://www.jmlr.org/papers/volume27/26-0434/26-0434.pdf" }] }
  end

  def import_journal
    mloss_catalogue
    SyncMlossWorker.new.perform([@article_id])
  end

  def import_openalex(project: nil)
    previous = ENV.to_h.slice("FILE", "OUTPUT")
    Tempfile.create(["journal-import", ".json"]) do |input|
      Tempfile.create(["journal-result", ".json"]) do |output|
        candidate = { "identifier_kind" => "openalex", "identifier" => @work.fetch("id"),
          "source" => "citation", "file_url" => "#{@project.url}/blob/main/CITATION.bib" }
        candidate["project_id"] = project.id if project
        report = { "candidates" => [{ "input" => candidate, "assessment" => "metadata_agrees",
          "checks" => { "title" => true }, "lookup" => @work.fetch("id") }],
          "lookups" => { @work.fetch("id") => { "status" => "found", "work" => @work } } }
        File.write(input.path, JSON.generate(report))
        ENV.update("FILE" => input.path, "OUTPUT" => output.path)
        Rake::Task["papers:import_candidates"].reenable
        capture_io { Rake::Task["papers:import_candidates"].invoke }
        JSON.parse(File.read(output.path)).fetch("candidates").sole.fetch("import")
      end
    end
  ensure
    %w[FILE OUTPUT].each { |key| ENV[key] = previous[key] }
  end

  test "journal identity survives DOI-less OpenAlex enrichment and repeated journal refreshes" do
    import_journal
    paper = Paper.sole
    identity = paper.paper_identifiers.sole
    assert_equal ["jmlr", @article_id], [identity.source, identity.identifier]
    assert_nil paper.doi
    assert_equal @article_url, paper.external_url
    assert_no_difference ["Paper.count", "PaperIdentifier.count", "ProjectPaper.count"] do
      result = import_openalex
      assert_equal "updated", result["status"]
      assert_equal paper.id, result["paper_id"]
      assert_equal "unchanged", import_openalex["status"]
      expire_mloss
      import_journal
    end
    assert_equal @work, paper.reload.openalex_data
    assert_equal Date.new(2026, 10, 1), paper.publication_date.to_date
    assert_equal "software_description", @project.project_papers.sole.role
    assert_equal 1, @project.project_papers.sole.evidence.size
  end

  test "OpenAlex first and legacy PDF-only papers are reused by journal imports" do
    @work["locations"] = [{ "pdf_url" => "http://jmlr.org/papers/volume27/26-0434/26-0434.pdf" }]
    result = import_openalex
    assert_equal "created", result["status"]
    paper = Paper.find(result["paper_id"])
    assert_equal @article_id, paper.paper_identifiers.sole.identifier
    paper.paper_identifiers.delete_all
    assert_no_difference "Paper.count" do
      import_journal
    end
    assert_equal paper.id, @project.project_papers.sole.paper_id
    assert_equal @work, paper.reload.openalex_data
    assert_includes paper.urls, @article_url
    assert_equal @article_id, paper.paper_identifiers.sole.identifier
  end

  test "publisher identity can receive an article DOI without treating software archive links as paper identifiers" do
    @mloss_html.sub!("</dd>", '<a href="https://doi.org/10.5281/zenodo.12345">code</a></dd>')
    import_journal
    paper = Paper.sole
    assert_nil paper.doi
    assert_equal [@article_url], paper.urls
    @work["doi"] = "https://doi.org/10.1234/article"
    assert_no_difference "Paper.count" do
      assert_equal paper.id, import_openalex["paper_id"]
    end
    assert_equal "10.1234/article", paper.reload.doi
  end

  test "conflicting DOI and publisher identities are reported without merging papers" do
    import_journal
    paper = Paper.sole
    other = Paper.create!(doi: "10.1234/other", title: "Other article")
    before = [paper.attributes, other.attributes]
    @work["doi"] = "https://doi.org/10.1234/other"
    assert_no_difference ["Paper.count", "PaperIdentifier.count"] do
      result = import_openalex
      assert_equal "error", result["status"]
      assert_match "Multiple papers", result["reason"]
    end
    assert_equal before, [paper.reload.attributes, other.reload.attributes]
  end

  test "a publisher identifier cannot be reassigned to another OpenAlex work" do
    import_journal
    assert_equal "updated", import_openalex["status"]
    paper = Paper.sole
    before = paper.attributes
    @work["id"] = "https://openalex.org/W87654321"
    assert_equal "error", import_openalex["status"]
    assert_equal before, paper.reload.attributes
  end

  test "conflicting publisher article URLs roll back the entire OpenAlex import" do
    @work["locations"] << { "landing_page_url" => "https://www.jmlr.org/papers/v27/25-2553.html" }
    assert_no_difference ["Paper.count", "PaperIdentifier.count"] do
      result = import_openalex
      assert_equal "error", result["status"]
      assert_match "Conflicting publisher", result["reason"]
    end
    import_journal
    @work["locations"].shift
    paper = Paper.sole
    paper.update!(openalex_id: @work["id"])
    before = paper.attributes
    assert_equal "error", import_openalex["status"]
    assert_equal before, paper.reload.attributes
    assert_equal 1, PaperIdentifier.count
  end

  test "journal refresh removes only its evidence and preserves citation references and scoring" do
    import_journal
    assert_not ScienceScoreCalculator.new(@project).calculate[:breakdown][:has_resolved_paper][:present]
    import_openalex(project: @project)
    link = @project.project_papers.sole
    assert_equal "reference", link.role
    assert_equal %w[mloss citation], link.evidence.pluck("source")
    assert ScienceScoreCalculator.new(@project).calculate[:breakdown][:has_resolved_paper][:present]
    expire_mloss
    @mloss_html.sub!(@project.url, "https://example.org/software")
    import_journal
    assert_equal "reference", link.reload.role
    assert_equal ["citation"], link.evidence.pluck("source")
    assert_equal 1, Paper.count
  end

  test "newly ambiguous repository matches remove publication attribution" do
    import_journal
    other = Project.create!(url: "https://github.com/another/neuraloperator")
    other.repository_aliases.create!(url: @project.url)
    expire_mloss
    import_journal
    assert_empty ProjectPaper.all
    assert_equal 1, Paper.count
    assert_equal %w[ambiguous ambiguous], ProjectExternalSoftwareRecord.pluck(:match_status)
  end

  test "lookalike hosts and mismatched PDF filenames do not match publisher identities" do
    import_journal
    @work["locations"] = [
      { "landing_page_url" => "https://jmlr.org.example/papers/v27/26-0434.html" },
      { "landing_page_url" => "https://jmlr.org@evil.example/papers/v27/26-0434.html" },
      { "pdf_url" => "https://jmlr.org/papers/volume27/26-0434/other.pdf" }
    ]
    assert_difference "Paper.count", 1 do
      assert_equal "created", import_openalex["status"]
    end
    assert_equal 1, PaperIdentifier.count
    assert_nil @project.project_papers.sole.paper.openalex_id
  end
end
