require "test_helper"
require "rake"
require "tempfile"

class PapersRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("papers:import_project_pairs")
    @previous_file = ENV["FILE"]
    @file = Tempfile.new(["project-paper-pairs", ".json"])
    ENV["FILE"] = @file.path
    @project = Project.create!(url: "https://github.com/example/model-code")
    @paper = Paper.create!(
      openalex_id: "https://openalex.org/W12345",
      doi: "10.1000/model-paper",
      title: "A model paper",
      openalex_data: { "id" => "https://openalex.org/W12345", "title" => "A model paper" }
    )
    @evidence = { "source" => "model_card", "url" => "https://huggingface.co/example/model", "quote" => "Code for our paper" }
    @row = { "repository_url" => @project.url, "openalex_id" => @paper.openalex_id, "evidence" => [@evidence] }
  end

  teardown do
    ENV["FILE"] = @previous_file
    @file.close!
  end

  def import_rows(rows)
    File.write(@file.path, rows.to_json)
    Rake::Task["papers:import_project_pairs"].reenable
    capture_io { Rake::Task["papers:import_project_pairs"].invoke }.first
  end

  test "imports verified pairs through the task without changing mentions or OpenAlex metadata" do
    mentioned_paper = Paper.create!(title: "A paper using this model")
    Mention.create!(project: @project, paper: mentioned_paper)
    original_metadata = @paper.attributes
    row = @row.merge("repository_url" => "https://github.com/EXAMPLE/MODEL-CODE.git/", "openalex_id" => "w12345")

    assert_difference "ProjectPaper.count", 1 do
      assert_no_difference "Mention.count" do
        assert_includes import_rows([row]), "created: 1"
      end
    end

    assert_equal [@paper], @project.linked_papers.to_a
    assert_equal [@project], @paper.linked_projects.to_a
    assert_equal [mentioned_paper], @project.papers.to_a
    assert_empty @paper.projects
    assert_equal original_metadata, @paper.reload.attributes
    assert_equal [@evidence], @project.project_papers.sole.evidence
  end

  test "reimport deduplicates pairs and retains additional evidence" do
    import_rows([@row])
    assert_includes import_rows([@row]), "unchanged: 1"

    citation = { "source" => "repository_citation", "url" => "https://github.com/example/model-code/blob/main/CITATION.cff" }
    assert_no_difference "ProjectPaper.count" do
      assert_includes import_rows([@row.merge("evidence" => [citation])]), "updated: 1"
    end
    assert_equal [@evidence, citation], @project.project_papers.sole.evidence
  end

  test "supports multiple papers per repository and multiple repositories per paper" do
    other_project = Project.create!(url: "https://github.com/example/other-model-code")
    other_paper = Paper.create!(openalex_id: "https://openalex.org/W67890")
    rows = [@row, @row.merge("openalex_id" => other_paper.openalex_id), @row.merge("repository_url" => other_project.url)]

    assert_difference "ProjectPaper.count", 3 do
      import_rows(rows)
    end
    assert_equal [@paper.id, other_paper.id].sort, @project.linked_papers.pluck(:id).sort
    assert_equal [@project.id, other_project.id].sort, @paper.linked_projects.pluck(:id).sort

    other_project.destroy!
    assert_equal 2, @project.project_papers.count
    assert_empty other_paper.mentions
    @paper.destroy!
    assert_equal [other_paper], @project.linked_papers.reload.to_a
  end

  test "resolves repository aliases and refuses ambiguous matches" do
    alias_url = "https://github.com/example/previous-name"
    ProjectRepositoryAlias.create!(project: @project, url: alias_url)
    assert_includes import_rows([@row.merge("repository_url" => alias_url.upcase)]), "created: 1"

    other_project = Project.create!(url: "https://github.com/example/another-project")
    ProjectRepositoryAlias.create!(project: other_project, url: alias_url)
    assert_raises(ArgumentError) { import_rows([@row.merge("repository_url" => alias_url)]) }
    assert_empty other_project.project_papers
  end

  test "rolls back the batch when an OpenAlex paper is missing or ambiguous" do
    assert_no_difference "ProjectPaper.count" do
      assert_raises(ArgumentError) do
        import_rows([@row, @row.merge("openalex_id" => "W99999")])
      end
    end
    Paper.create!(openalex_id: "w12345")
    assert_raises(ArgumentError) { import_rows([@row]) }
    assert_empty @project.project_papers
  end

  test "refuses missing projects without creating records" do
    assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count"] do
      assert_raises(ArgumentError) do
        import_rows([@row.merge("repository_url" => "https://github.com/example/missing")])
      end
    end
  end

  test "requires attributable evidence even when a pair already exists" do
    import_rows([@row])
    [nil, {}, [], ["paper"], [{ "source" => "model_card" }], [{ "source" => [], "url" => "example" }]].each do |evidence|
      assert_raises(ActiveRecord::RecordInvalid) { import_rows([@row.merge("evidence" => evidence)]) }
    end
    assert_equal [@evidence], @project.project_papers.sole.evidence
  end
end
