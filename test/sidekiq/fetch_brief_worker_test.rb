require "test_helper"

class FetchBriefWorkerTest < ActiveSupport::TestCase
  setup do
    FetchBriefWorker.jobs.clear
  end

  test "uses the dedicated brief queue" do
    assert_equal "brief", FetchBriefWorker.get_sidekiq_options["queue"]
    assert_equal 3, FetchBriefWorker.get_sidekiq_options["retry"]
  end

  test "stores Brief data and recalculates the science score" do
    project = Project.create!(
      url: "https://github.com/test/brief-worker",
      repository: { "clone_url" => "https://github.com/test/brief-worker.git" },
      science_score: 1
    )
    output = {
      version: "0.12.0",
      languages: [{ name: "Fortran" }],
      package_managers: [],
      tools: {},
      resources: {},
      manifests: [],
      dependencies: [
        {
          name: "numpy",
          purl: "pkg:pypi/numpy",
          scope: "runtime",
          direct: true,
        },
      ],
      lines: {},
    }.to_json
    Open3.expects(:capture3).returns([output, "", stub(success?: true)])

    FetchBriefWorker.new.perform(project.id)

    assert_equal "Fortran", project.reload.brief.dig("languages", 0, "name")
    assert_equal "pkg:pypi/numpy", project.brief.dig("dependencies", 0, "purl")
    assert_equal 20.0, project.science_score
    assert project.science_score_breakdown.dig(:breakdown, :has_research_tooling, :present)
  end

  test "does not score standalone R authoring tools without scientific vocabulary" do
    project = Project.create!(
      url: "https://github.com/test/r-markdown-report",
      repository: { "clone_url" => "https://github.com/test/r-markdown-report.git" },
      science_score: 1
    )
    output = {
      version: "0.12.0",
      languages: [{ name: "R" }],
      package_managers: [],
      tools: { docs: [{ name: "R Markdown" }, { name: "knitr" }] },
      resources: {},
      manifests: [],
      lines: {},
    }.to_json
    Open3.expects(:capture3).returns([output, "", stub(success?: true)])
    JossVocabularyAnalyzer.stubs(:analyze_project).returns(score: 0, terms: [], model_id: nil)

    FetchBriefWorker.new.perform(project.id)

    project.reload
    assert_equal 0.0, project.science_score
    assert_equal 0.4, project.science_score_breakdown.dig(:breakdown, :has_research_tooling, :strength)
    assert_equal 0.0, project.science_score_breakdown.dig(:breakdown, :has_research_tooling, :score)
  end

  test "skips a project that already has Brief dependency data" do
    project = Project.create!(
      url: "https://github.com/test/already-scanned",
      repository: { "clone_url" => "https://github.com/test/already-scanned.git" },
      science_score: 20,
      brief: { "version" => "0.12.1", "dependencies" => [] }
    )
    Project.any_instance.expects(:fetch_brief).never

    FetchBriefWorker.new.perform(project.id)
  end

  test "rescans a successful legacy Brief result and makes an empty repos result eligible again" do
    project = Project.create!(
      url: "https://github.com/test/legacy-brief",
      repository: { "clone_url" => "https://github.com/test/legacy-brief.git" },
      science_score: 20,
      brief: { "version" => "0.12.0", "languages" => [] },
      dependencies: [],
      dependencies_indexed_at: 1.day.ago
    )
    output = {
      version: "0.12.1",
      languages: [],
      package_managers: [],
      tools: {},
      resources: {},
      manifests: [],
      dependencies: [
        {
          name: "rails",
          purl: "pkg:gem/rails",
          scope: "runtime",
          direct: true,
        },
      ],
      lines: {},
    }.to_json
    Open3.expects(:capture3).returns([output, "", stub(success?: true)])

    FetchBriefWorker.new.perform(project.id)

    assert_equal "pkg:gem/rails", project.reload.brief.dig("dependencies", 0, "purl")
    assert_nil project.dependencies_indexed_at

    result = Project.sync_dependencies(limit: 1)

    assert_equal 1, result.fetch(:indexed)
    dependency = project.project_dependencies.reload.sole
    assert_equal "rails", dependency.package_name
    assert_equal "brief", dependency.metadata.fetch("source")
  end
end
