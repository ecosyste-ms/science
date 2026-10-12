require "test_helper"
require "rake"
require "tempfile"

class PackagePapersRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:import_package_pairs")
    @previous_file = ENV["FILE"]
    @file = Tempfile.new(["package-paper-pairs", ".json"])
    ENV["FILE"] = @file.path
    registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    @package = Package.create!(package_registry: registry, name: "allenai/specter2_base", purl: "pkg:huggingface/allenai/specter2_base")
    @paper = Paper.create!(openalex_id: "https://openalex.org/W4389524502",
      doi: "10.18653/v1/2023.emnlp-main.338", title: "SciRepEval",
      openalex_data: { "id" => "https://openalex.org/W4389524502", "title" => "SciRepEval" })
    @evidence = {
      "source" => "model_card", "url" => "https://huggingface.co/allenai/specter2_base/resolve/#{'a' * 40}/README.md",
      "revision" => 'a' * 40, "paper_identifier" => "CorpusId:254018137", "line_start" => 71,
      "passage" => "Paper: https://api.semanticscholar.org/CorpusID:254018137"
    }
    @row = { "purl" => @package.purl, "openalex_id" => @paper.openalex_id, "role" => "model_family_paper", "evidence" => [@evidence] }
  end

  teardown do
    ENV["FILE"] = @previous_file
    @file.close!
  end

  def import_rows(rows)
    File.write(@file.path, rows.to_json)
    Rake::Task["papers:import_package_pairs"].reenable
    capture_io { Rake::Task["papers:import_package_pairs"].invoke }.first
  end

  test "imports by purl without a repository or changes to canonical paper data" do
    original_paper = @paper.attributes
    original_package = @package.attributes
    row = @row.merge("purl" => "pkg:HuggingFace/allenai/specter2_base@#{'a' * 40}", "openalex_id" => "w4389524502")

    assert_difference "PackagePaper.count", 1 do
      assert_no_difference ["Mention.count", "ProjectPaper.count", "Project.count"] do
        assert_includes import_rows([row]), "created: 1"
      end
    end
    assert_equal [@paper], @package.linked_papers.to_a
    assert_equal [@package], @paper.linked_packages.to_a
    assert_equal [@evidence], @package.package_papers.sole.evidence
    assert_equal original_paper, @paper.reload.attributes
    assert_equal original_package, @package.reload.attributes
  end

  test "retains distinct roles for the same paper with distinct supporting evidence" do
    evaluation = @evidence.merge("line_start" => 56, "passage" => "We evaluate the trained model on this benchmark.")
    rows = [@row, @row.merge("role" => "evaluation", "evidence" => [evaluation])]
    assert_difference "PackagePaper.count", 2 do
      import_rows(rows)
    end
    assert_equal [@paper], @package.linked_papers.to_a
    assert_equal [@package], @paper.linked_packages.to_a
    assert_equal [evaluation], @package.package_papers.find_by!(role: "evaluation").evidence
    assert_equal [@evidence], @package.package_papers.find_by!(role: "model_family_paper").evidence
    assert_includes import_rows(rows), "unchanged: 2"
  end

  test "preserves evidence from multiple model revisions and repeated import is unchanged" do
    import_rows([@row])
    first = @package.package_papers.sole
    updated_at = first.updated_at
    assert_includes import_rows([@row]), "unchanged: 1"
    assert_equal updated_at, first.reload.updated_at

    later = @evidence.merge("revision" => 'b' * 40, "url" => @evidence["url"].sub('a' * 40, 'b' * 40))
    assert_no_difference "PackagePaper.count" do
      assert_includes import_rows([@row.merge("evidence" => [later])]), "updated: 1"
    end
    assert_equal [@evidence, later], first.reload.evidence
  end

  test "only papers describing the model or its family lead to linked code projects" do
    model_project = Project.create!(url: "https://github.com/allenai/SPECTER2")
    other_project = Project.create!(url: "https://github.com/example/benchmark")
    other_paper = Paper.create!(openalex_id: "https://openalex.org/W12345")
    ProjectPaper.create!(project: model_project, paper: @paper, evidence: [@evidence])
    ProjectPaper.create!(project: other_project, paper: other_paper, evidence: [@evidence])
    rows = [@row, @row.merge("role" => "evaluation")]
    %w[base_model_paper method training_data evaluation].each do |role|
      rows << @row.merge("role" => role, "openalex_id" => other_paper.openalex_id)
    end

    import_rows(rows)

    assert_equal [@paper.id, other_paper.id].sort, @package.linked_papers.pluck(:id).sort
    assert_equal [model_project], @package.linked_projects.to_a
    assert_nil @package.reload.published_by_project_id
  end

  test "supports multiple papers and model variants and cleans up only the join rows" do
    other_package = Package.create!(package_registry: @package.package_registry, name: "allenai/specter2", purl: "pkg:huggingface/allenai/specter2")
    other_paper = Paper.create!(openalex_id: "https://openalex.org/W12345")
    rows = [@row, @row.merge("purl" => other_package.purl), @row.merge("openalex_id" => other_paper.openalex_id, "role" => "base_model_paper")]
    assert_difference "PackagePaper.count", 3 do
      import_rows(rows)
    end
    assert_equal [@paper.id, other_paper.id].sort, @package.linked_papers.pluck(:id).sort
    assert_equal [@package.id, other_package.id].sort, @paper.linked_packages.pluck(:id).sort
    other_package.destroy!
    assert_equal 2, @package.package_papers.count
    @paper.destroy!
    assert_equal [other_paper], @package.linked_papers.reload.to_a
    assert Package.exists?(@package.id)
  end

  test "rejects unknown packages and malformed purls without creating identities" do
    ["pkg:huggingface/unknown/model", "not a purl"].each do |purl|
      assert_no_difference ["Package.count", "Paper.count", "PackagePaper.count"] do
        assert_raises(ArgumentError, Purl::Error) { import_rows([@row, @row.merge("purl" => purl)]) }
      end
    end
  end

  test "does not conflate registries or case-sensitive purl namespaces" do
    foreign = @row.merge("purl" => "#{@package.purl}?repository_url=https://other.example")
    assert_raises(ArgumentError) { import_rows([foreign]) }
    differently_cased = Package.create!(package_registry: @package.package_registry, name: "AllenAI/specter2_base", purl: "pkg:huggingface/AllenAI/specter2_base")
    import_rows([@row])
    assert_empty differently_cased.package_papers
  end

  test "rolls back on missing or ambiguous OpenAlex identities" do
    assert_no_difference "PackagePaper.count" do
      assert_raises(ArgumentError) { import_rows([@row, @row.merge("openalex_id" => "W99999")]) }
    end
    Paper.create!(openalex_id: "w4389524502")
    assert_raises(ArgumentError) { import_rows([@row]) }
    assert_empty @package.package_papers
  end

  test "requires a known role and attributable evidence on every import" do
    import_rows([@row])
    [nil, "", "unknown"].each do |role|
      assert_raises(ActiveRecord::RecordInvalid) { import_rows([@row.merge("role" => role)]) }
    end
    [nil, {}, [], ["paper"], [{ "source" => "model_card" }], [{ "source" => [], "url" => "example" }]].each do |evidence|
      assert_raises(ActiveRecord::RecordInvalid) { import_rows([@row.merge("evidence" => evidence)]) }
    end
    assert_equal [@evidence], @package.package_papers.sole.evidence
    assert_raises(ActiveRecord::RecordInvalid) { @package.package_papers.sole.dup.save! }
  end
end
