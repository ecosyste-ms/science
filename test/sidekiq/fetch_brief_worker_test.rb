require "test_helper"

class FetchBriefWorkerTest < ActiveSupport::TestCase
  setup do
    FetchBriefWorker.jobs.clear
    ProjectRepositoryScanner.any_instance.stubs(:with_checkout).yields("/tmp/checkout", "https://github.com/test/repository", [])
  end

  test "uses the dedicated brief queue" do
    assert_equal "brief", FetchBriefWorker.get_sidekiq_options["queue"]
    assert_equal 3, FetchBriefWorker.get_sidekiq_options["retry"]
  end

  test "stores Brief data and recalculates the science score" do
    project = Project.create!(
      url: "https://github.com/test/brief-worker",
      repository: { "clone_url" => "https://github.com/test/brief-worker.git" },
      swhids: { "status" => "success" }, science_score: 1
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
    RepositoryCommand.any_instance.expects(:run).with(["brief", "-json", "/tmp/checkout"]).returns(output)

    Project.expects(:eligible_for_brief).never
    Package.expects(:direct_scientific_dependencies).never
    FetchBriefWorker.new.perform(project.id)

    assert_equal "Fortran", project.reload.brief.dig("languages", 0, "name")
    assert_equal "pkg:pypi/numpy", project.brief.dig("dependencies", 0, "purl")
    assert_equal 20.0, project.science_score
    assert project.science_score_breakdown.dig(:breakdown, :has_research_tooling, :present)
  end

  test "zero-score publisher eligibility checks dependencies only for its own packages" do
    project = Project.create!(url: "https://example.test/publisher", science_score: 0, repository: { "clone_url" => "https://example.test/publisher.git" }, swhids: { "status" => "success" })
    unrelated = Project.create!(url: "https://example.test/unrelated-publisher", science_score: 0, repository: { "clone_url" => "https://example.test/unrelated.git" }, swhids: { "status" => "success" })
    registry = PackageRegistry.create!(name: "scoped-brief.example", url: "https://scoped-brief.example", ecosystem: "pypi", purl_type: "pypi")
    package = Package.create!(package_registry: registry, published_by_project: project, name: "research-input", purl: "pkg:pypi/research-input")
    dependent = Project.create!(url: "https://example.test/scientific-dependent", science_score: 20)
    ProjectDependency.create!(project: dependent, package: package, ecosystem: "pypi", package_name: package.name, direct: true)
    output = { languages: [{ name: "Fortran" }], tools: {}, dependencies: [] }.to_json
    RepositoryCommand.any_instance.expects(:run).with(["brief", "-json", "/tmp/checkout"]).once.returns(output)
    Package.expects(:scientific_publishing_project_ids).never
    dependency_queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { dependency_queries << payload if payload[:sql].include?('FROM "project_dependencies"') }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      FetchBriefWorker.new.perform(unrelated.id)
      FetchBriefWorker.new.perform(project.id)
    end

    assert_nil unrelated.reload.brief
    assert_operator project.reload.science_score, :>=, Project::SCIENCE_SCORE_THRESHOLD
    assert_equal 2, dependency_queries.size
    dependency_queries.each do |query|
      assert_includes query[:sql], '"packages"."published_by_project_id" ='
      refute_includes query[:sql], 'DISTINCT'
    end
  end

  test "does not score standalone R authoring tools without scientific vocabulary" do
    project = Project.create!(
      url: "https://github.com/test/r-markdown-report",
      repository: { "clone_url" => "https://github.com/test/r-markdown-report.git" },
      swhids: { "status" => "success" }, science_score: 1
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
    RepositoryCommand.any_instance.expects(:run).with(["brief", "-json", "/tmp/checkout"]).returns(output)
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
      swhids: { "status" => "success" }, science_score: 20,
      brief: { "version" => "0.12.1", "dependencies" => [] }
    )
    Project.any_instance.expects(:fetch_brief).never

    FetchBriefWorker.new.perform(project.id)
  end

  test "rescans a successful legacy Brief result and makes an empty repos result eligible again" do
    project = Project.create!(
      url: "https://github.com/test/legacy-brief",
      repository: { "clone_url" => "https://github.com/test/legacy-brief.git" },
      swhids: { "status" => "success" }, science_score: 20,
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
    RepositoryCommand.any_instance.expects(:run).with(["brief", "-json", "/tmp/checkout"]).returns(output)

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
