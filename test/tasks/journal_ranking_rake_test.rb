require "test_helper"
require "rake"
require "tempfile"

class JournalRankingRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("journals:rank")
    @project = Project.create!(url: "https://github.com/example/software")
    registry = PackageRegistry.create!(name: "huggingface.co", ecosystem: "huggingface", purl_type: "huggingface", url: "https://huggingface.co")
    @package = registry.packages.create!(name: "example/model", purl: "pkg:huggingface/example/model")
    @evidence = [{ "source" => "citation", "url" => @project.url }]
  end

  def paper(source: "https://openalex.org/S123", issn: "1234-567X", type: "journal", name: "Example Journal")
    Paper.create!(title: "Example paper", openalex_id: "W#{Paper.maximum(:id).to_i + 1}",
      openalex_data: { "primary_location" => { "source" => { "id" => source, "issn_l" => issn, "type" => type, "display_name" => name } } })
  end

  def rank(limit: 100)
    before = ENV.to_h.slice("OUTPUT", "LIMIT")
    Tempfile.create(["journal-ranking", ".json"]) do |output|
      ENV.update("OUTPUT" => output.path, "LIMIT" => limit.to_s)
      Rake::Task["journals:rank"].reenable
      counts = [Paper.count, ProjectPaper.count, PackagePaper.count, Mention.count]
      capture_io { Rake::Task["journals:rank"].invoke }
      assert_equal counts, [Paper.count, ProjectPaper.count, PackagePaper.count, Mention.count]
      JSON.parse(File.read(output.path))
    end
  ensure
    %w[OUTPUT LIMIT].each { |key| ENV[key] = before[key] }
  end

  test "distinct software paper pairs preserve relationship roles and reconcile source IDs with ISSNs" do
    first = paper(source: "HTTP://OPENALEX.ORG/s123")
    second = paper(source: nil, issn: "1234-567x")
    @project.project_papers.create!(paper: first, role: "reference", evidence: @evidence + [{ "source" => "mloss", "url" => @project.url, "relationship" => "software_description" }])
    @project.mentions.create!(paper: first)
    @project.project_papers.create!(paper: second, role: "reference", evidence: @evidence)
    @package.package_papers.create!(paper: first, role: "model_paper", evidence: @evidence)
    @package.package_papers.create!(paper: first, role: "reference", evidence: @evidence)
    report = rank
    row = report["journals"].sole
    assert_equal "https://openalex.org/S123", row["source_id"]
    assert_equal "1234-567X", row["issn"]
    assert_equal 2, row["papers"]
    assert_equal 1, row["projects"]
    assert_equal 1, row["packages"]
    assert_equal 3, row["software_paper_pairs"]
    assert_equal 2, row["direct_pairs"]
    assert_equal 1, row["reference_only_pairs"]
    assert_equal 1, row["model_pairs"]
    assert_equal 1, row["software_description_pairs"]
  end

  test "JOSS mention provenance contributes description evidence without duplicating a project paper pair" do
    publication = paper
    mention = @project.mentions.create!(paper: publication, created_by_source: "joss")
    MentionSource.create!(mention: mention, source: "joss", source_identifier: "10.21105/joss.12345", source_digest: "test", raw_data: {})
    @project.project_papers.create!(paper: publication, role: "reference", evidence: @evidence)
    row = rank["journals"].sole
    assert_equal 1, row["software_paper_pairs"]
    assert_equal 1, row["software_description_pairs"]
    assert_equal 0, row["reference_only_pairs"]
  end

  test "repositories unknown source types and missing source metadata are reported separately" do
    repository = paper(source: "https://openalex.org/S456", issn: nil, type: "repository", name: "Example Archive")
    unknown = paper(source: nil, issn: "9999-123X", type: nil)
    missing = Paper.create!(title: "DOI-less journal paper")
    [repository, unknown, missing].each { |publication| @project.project_papers.create!(paper: publication, role: "reference", evidence: @evidence) }
    report = rank
    assert_empty report["journals"]
    assert_equal "repository", report["other_sources"].sole["source_type"]
    assert_equal "issn:9999-123X", report["unknown_sources"].sole["source_key"]
    assert_equal 1, report["summary"]["missing_source_papers"]
    assert_equal 1, report["summary"]["papers_without_openalex_id"]
    assert_equal 3, report["summary"]["linked_papers"]
  end

  test "hidden projects and their published packages and unassociated papers are excluded" do
    host = Host.create!(name: "GitHub", url: "https://github.com", kind: "GitHub")
    owner = Owner.create!(host: host, login: "example")
    @project.update!(owner_record: owner)
    @package.update!(published_by_project: @project)
    owner.update!(hidden: true)
    publication = paper
    @project.project_papers.create!(paper: publication, role: "reference", evidence: @evidence)
    @package.package_papers.create!(paper: publication, role: "model_paper", evidence: @evidence)
    paper(source: "https://openalex.org/S789")
    report = rank
    assert_equal 0, report["summary"]["linked_papers"]
    assert_empty report["journals"]
  end

  test "output limits retain population totals and direct pairs precede reference-only sources" do
    referenced = paper(source: "https://openalex.org/S100", issn: "1111-1111")
    described = paper(source: "https://openalex.org/S200", issn: "2222-2222")
    @project.project_papers.create!(paper: referenced, role: "reference", evidence: @evidence)
    @project.project_papers.create!(paper: described, role: "software_description", evidence: @evidence)
    report = rank(limit: 1)
    assert_equal true, report["truncated"]
    assert_equal 2, report["summary"]["sources"]
    assert_equal "https://openalex.org/S200", report["journals"].sole["source_id"]
    assert_raises(ArgumentError) { rank(limit: 1001) }
  end
end
