require "test_helper"
require "rake"

class ProjectsRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[LIMIT COHORT SHARD_COUNT SHARD].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:fetch_brief")
    ENV_KEYS.each { |key| ENV.delete(key) }
    FetchBriefWorker.jobs.clear
  end

  teardown do
    ENV_KEYS.each { |key| ENV.delete(key) }
    FetchBriefWorker.jobs.clear
  end

  test "fetch_brief enqueues eligible projects through the application service" do
    joss = create_project("joss", joss: true)
    create_project("non-joss")
    ENV["LIMIT"] = "10"
    ENV["COHORT"] = "joss"

    output, = capture_io { Rake::Task["projects:fetch_brief"].execute }

    assert_equal [[joss.id]], FetchBriefWorker.jobs.map { |job| job["args"] }
    assert_includes output, "Enqueued 1 Brief jobs"
    assert_includes output, "cohort=joss"
  end

  test "fetch_brief rejects an invalid cohort" do
    ENV["COHORT"] = "unknown"

    assert_raises(SystemExit) do
      capture_io { Rake::Task["projects:fetch_brief"].execute }
    end
    assert_empty FetchBriefWorker.jobs
  end

  def create_project(name, joss: false, brief: nil, science_score: 20, repository: true)
    Project.create!(
      url: "https://github.com/test/#{name}",
      repository: repository ? { "clone_url" => "https://github.com/test/#{name}.git" } : nil,
      science_score: science_score,
      brief: brief,
      joss_metadata: joss ? { "doi" => "10.21105/joss.test" } : nil
    )
  end
end
