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
      lines: {},
    }.to_json
    Open3.expects(:capture3).returns([output, "", stub(success?: true)])

    FetchBriefWorker.new.perform(project.id)

    assert_equal "Fortran", project.reload.brief.dig("languages", 0, "name")
    assert_equal 20.0, project.science_score
    assert project.science_score_breakdown.dig(:breakdown, :has_research_tooling, :present)
  end

  test "skips a project that already has brief data" do
    project = Project.create!(
      url: "https://github.com/test/already-scanned",
      repository: { "clone_url" => "https://github.com/test/already-scanned.git" },
      science_score: 20,
      brief: { "version" => "0.12.0" }
    )
    Project.any_instance.expects(:fetch_brief).never

    FetchBriefWorker.new.perform(project.id)
  end
end
