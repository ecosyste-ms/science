require "test_helper"
require "rake"
require "tmpdir"

class LocalPaperCandidatesRakeTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:import_candidates")
    @previous_env = ENV.to_h.slice("FILE", "OUTPUT", "LOCAL_ONLY", "OPENALEX_API_KEY")
    @directory = Dir.mktmpdir("local-paper-candidates")
    @paper = Paper.import_publication!(title: "Odyssey", url: "https://arxiv.org/abs/1601.02063")
  end

  teardown do
    %w[FILE OUTPUT LOCAL_ONLY OPENALEX_API_KEY].each { |key| ENV[key] = @previous_env[key] }
    FileUtils.remove_entry(@directory)
  end

  def import_local_references(project)
    candidates = project.paper_file_candidates("readme", project.readme, "readme_bibtex")
    ENV["FILE"] = File.join(@directory, "candidates.json")
    ENV["OUTPUT"] = File.join(@directory, "references.json")
    ENV["LOCAL_ONLY"] = "1"
    ENV.delete("OPENALEX_API_KEY")
    File.write(ENV.fetch("FILE"), candidates.to_json)
    Rake::Task["papers:import_candidates"].reenable
    capture_io { Rake::Task["papers:import_candidates"].invoke }
    JSON.parse(File.read(ENV.fetch("OUTPUT")))
  end

  test "local candidate task discovers another repository reference without network or title matching" do
    paper = @paper
    other = Project.create!(url: "https://github.com/example/analysis", readme: "## References\nhttps://arxiv.org/abs/1601.02063v3\nhttps://arxiv.org/abs/2401.00001\n")
    assert_difference "ProjectPaper.count", 1 do
      assert_no_difference "Paper.count" do
        result = import_local_references(other)
        assert_equal({ "linked" => 1, "skipped" => 1 }, result["import_summary"])
        assert_equal %w[local_identifier not_found], result["candidates"].map { |c| c["assessment"] }
      end
    end
    link = other.project_papers.sole
    assert_equal paper, link.paper
    assert_equal "reference", link.role
    assert_equal "stored_project_readme", link.evidence.sole["source"]
    assert_includes link.evidence.sole["occurrences"].sole["raw"], "1601.02063v3"
    attributes = link.attributes
    import_local_references(other)
    assert_equal attributes, link.reload.attributes
    link.update!(role: "software_description")
    import_local_references(other)
    assert_equal "software_description", link.reload.role
  end

  test "local candidate task preserves ambiguous DOI identities instead of using the archive identifier alone" do
    Paper.create!(title: "Conflicting record", doi: "10.48550/arxiv.1601.02063")
    other = Project.create!(url: "https://github.com/example/analysis", readme: "https://arxiv.org/abs/1601.02063")
    assert_no_difference ["Paper.count", "ProjectPaper.count"] do
      result = import_local_references(other)
      assert_equal "ambiguous", result["candidates"].sole["assessment"]
      assert_equal "skipped", result["candidates"].sole.dig("import", "status")
    end
  end
end
