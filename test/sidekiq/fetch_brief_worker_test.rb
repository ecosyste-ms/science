require "test_helper"

class FetchBriefWorkerTest < ActiveSupport::TestCase
  setup do
    FetchBriefWorker.jobs.clear
  end

  test "uses the dedicated brief queue" do
    assert_equal "brief", FetchBriefWorker.get_sidekiq_options["queue"]
    assert_equal 3, FetchBriefWorker.get_sidekiq_options["retry"]
  end

  test "fetches brief data for an unscanned project" do
    project = Project.create!(
      url: "https://github.com/test/brief-worker",
      repository: { "clone_url" => "https://github.com/test/brief-worker.git" },
      science_score: 20
    )
    Project.any_instance.expects(:fetch_brief).once

    FetchBriefWorker.new.perform(project.id)
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
