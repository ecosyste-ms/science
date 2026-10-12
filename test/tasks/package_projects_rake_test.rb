require "test_helper"
require "rake"
require "tempfile"

class PackageProjectsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:import_project_pairs")
    @previous_file = ENV["FILE"]
    @file = Tempfile.new(["package-project-pairs", ".json"])
    ENV["FILE"] = @file.path
    registry = PackageRegistry.create!(name: "HuggingFace.co", url: "https://huggingface.co", ecosystem: "huggingface", purl_type: "huggingface")
    @package = Package.create!(package_registry: registry, name: "sentence-transformers/all-mpnet-base-v2", purl: "pkg:huggingface/sentence-transformers/all-mpnet-base-v2")
    @project = Project.create!(url: "https://github.com/huggingface/sentence-transformers")
    @runtime = Project.create!(url: "https://github.com/huggingface/text-embeddings-inference")
    @evidence = { "source" => "repository_review",
      "url" => "#{@project.url}/blob/#{'a' * 40}/docs/sentence_transformer/pretrained_models.md",
      "commit" => 'a' * 40, "line" => 62, "passage" => "Original models: sentence-transformers/all-mpnet-base-v2" }
    @row = { "purl" => @package.purl, "repository_url" => @project.url, "role" => "model_library", "evidence" => [@evidence] }
  end

  teardown do
    ENV["FILE"] = @previous_file
    @file.close!
  end

  def import_rows(rows)
    File.write(@file.path, rows.to_json)
    Rake::Task["packages:import_project_pairs"].reenable
    capture_io { Rake::Task["packages:import_project_pairs"].invoke }.first
  end

  test "imports reviewed direct links by purl without changing publication or paper data" do
    original_package = @package.attributes
    original_project = @project.attributes
    row = @row.merge("purl" => "pkg:HuggingFace/sentence-transformers/all-mpnet-base-v2@#{'b' * 40}#model",
      "repository_url" => "https://GitHub.com/HuggingFace/Sentence-Transformers.git")

    assert_difference "PackageProject.count", 1 do
      assert_no_difference ["Project.count", "Package.count", "Paper.count", "Mention.count", "ProjectPaper.count", "PackagePaper.count"] do
        assert_includes import_rows([row]), "created: 1"
      end
    end
    assert_equal [@project], @package.linked_projects.to_a
    assert_equal [@evidence], @package.package_projects.sole.evidence
    assert_equal [@package.id], @project.package_projects.pluck(:package_id)
    assert_equal original_package, @package.reload.attributes
    assert_equal original_project, @project.reload.attributes
  end

  test "retains reciprocal runtime evidence without treating it as model code" do
    runtime_evidence = @evidence.merge("url" => "#{@runtime.url}/blob/#{'c' * 40}/README.md",
      "passage" => "Supported models: sentence-transformers/all-mpnet-base-v2")
    import_rows([@row, @row.merge("repository_url" => @runtime.url, "role" => "supported_runtime", "evidence" => [runtime_evidence])])

    assert_equal [@project], @package.linked_projects.to_a
    runtime_pair = @package.package_projects.find_by!(role: "supported_runtime")
    assert_equal @runtime, runtime_pair.project
    assert_equal [runtime_evidence], runtime_pair.evidence
    assert_nil @package.reload.published_by_project_id
  end

  test "unions direct and paper links without duplicating projects or adding base-paper links" do
    paper_project = Project.create!(url: "https://github.com/example/research")
    paper = Paper.create!(openalex_id: "https://openalex.org/W12345", openalex_data: { "title" => "Model paper" })
    base_paper = Paper.create!(openalex_id: "https://openalex.org/W23456")
    ProjectPaper.create!(project: @project, paper: paper, evidence: [@evidence])
    ProjectPaper.create!(project: paper_project, paper: paper, evidence: [@evidence])
    ProjectPaper.create!(project: @runtime, paper: base_paper, evidence: [@evidence])
    PackagePaper.create!(package: @package, paper: paper, role: "model_family_paper", evidence: [@evidence])
    PackagePaper.create!(package: @package, paper: base_paper, role: "base_model_paper", evidence: [@evidence])

    import_rows([@row, @row.merge("role" => "inference_implementation"), @row.merge("repository_url" => @runtime.url, "role" => "supported_runtime")])

    assert_equal [@project.id, paper_project.id].sort, @package.linked_projects.pluck(:id).sort
    assert_equal 2, @package.linked_projects.count
  end

  test "keeps role-specific evidence and all implementation roles lead to code" do
    rows = PackageProject::ROLES.map { |role| @row.merge("role" => role, "evidence" => [@evidence.merge("role_review" => role)]) }
    assert_difference "PackageProject.count", 4 do
      import_rows(rows)
    end
    assert_equal [@project], @package.linked_projects.to_a
    @package.package_projects.each do |pair|
      assert_equal [@evidence.merge("role_review" => pair.role)], pair.evidence
    end
    @package.package_projects.where.not(role: "model_implementation").delete_all
    assert_equal [@project], @package.linked_projects.to_a
    @package.package_projects.update_all(role: "supported_runtime")
    assert_empty @package.linked_projects
  end

  test "repeated imports are unchanged and later evidence is appended" do
    import_rows([@row])
    pair = @package.package_projects.sole
    timestamp = pair.updated_at
    assert_includes import_rows([@row]), "unchanged: 1"
    assert_equal timestamp, pair.reload.updated_at
    later = @evidence.merge("commit" => 'b' * 40, "url" => @evidence["url"].sub('a' * 40, 'b' * 40))
    assert_no_difference "PackageProject.count" do
      assert_includes import_rows([@row.merge("evidence" => [later, later])]), "updated: 1"
    end
    assert_equal [@evidence, later], pair.reload.evidence
  end

  test "resolves repository aliases and rejects ambiguous aliases atomically" do
    old_url = "https://github.com/ukplab/sentence-transformers"
    ProjectRepositoryAlias.create!(project: @project, url: old_url)
    import_rows([@row.merge("repository_url" => old_url)])
    assert_equal @project, @package.package_projects.sole.project
    ProjectRepositoryAlias.create!(project: @runtime, url: old_url)
    assert_no_difference "PackageProject.count" do
      assert_raises(ArgumentError) { import_rows([@row.merge("role" => "model_implementation"), @row.merge("repository_url" => old_url)]) }
    end
  end

  test "rejects unknown identities and invalid evidence without partial imports" do
    [@row.merge("purl" => "pkg:huggingface/unknown/model"), @row.merge("purl" => "invalid"),
     @row.merge("repository_url" => "https://github.com/unknown/project"), @row.merge("repository_url" => "invalid"),
     @row.merge("role" => "unknown"), @row.merge("role" => nil),
     @row.merge("evidence" => []), @row.merge("evidence" => [{ "source" => "review" }]),
     @row.merge("evidence" => [{ "source" => [], "url" => "example" }])].each do |invalid|
      assert_no_difference ["PackageProject.count", "Package.count", "Project.count"] do
        assert_raises(ArgumentError, Purl::Error, ActiveRecord::RecordInvalid) { import_rows([@row, invalid]) }
      end
    end
    [nil, {}, [nil]].each do |invalid|
      assert_raises(ArgumentError) { import_rows(invalid) }
    end
  end

  test "does not conflate purl case or qualifiers" do
    other = Package.create!(package_registry: @package.package_registry, name: "Sentence-Transformers/all-mpnet-base-v2", purl: "pkg:huggingface/Sentence-Transformers/all-mpnet-base-v2")
    import_rows([@row])
    assert_empty other.package_projects
    assert_raises(ArgumentError) { import_rows([@row.merge("purl" => "#{@package.purl}?repository_url=https://other.example")]) }
  end

  test "enforces uniqueness and deletes only relationships with either endpoint" do
    import_rows([@row, @row.merge("repository_url" => @runtime.url, "role" => "supported_runtime")])
    assert_raises(ActiveRecord::RecordInvalid) { @package.package_projects.first.dup.save! }
    @project.destroy!
    assert_equal 1, @package.package_projects.count
    @package.destroy!
    assert_empty @runtime.package_projects
    assert Project.exists?(@runtime.id)
  end
end
