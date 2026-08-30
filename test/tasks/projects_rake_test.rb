require "test_helper"
require "rake"

class ProjectsRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[LIMIT COHORT SHARD_COUNT SHARD DRY_RUN RETRY_ERRORS].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:fetch_brief")
    ENV_KEYS.each { |key| ENV.delete(key) }
    FetchBriefWorker.jobs.clear
    SyncProjectWorker.jobs.clear
  end

  teardown do
    ENV_KEYS.each { |key| ENV.delete(key) }
    FetchBriefWorker.jobs.clear
    SyncProjectWorker.jobs.clear
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

  test "fetch_brief defaults to a batch of 50" do
    51.times { |index| create_project("default-limit-#{index}") }

    capture_io { Rake::Task["projects:fetch_brief"].execute }

    assert_equal 50, FetchBriefWorker.jobs.size
  end

  test "fetch_brief rejects an invalid cohort" do
    ENV["COHORT"] = "unknown"

    assert_raises(SystemExit) do
      capture_io { Rake::Task["projects:fetch_brief"].execute }
    end
    assert_empty FetchBriefWorker.jobs
  end

  test "sync_dependencies indexes a bounded project batch through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/dependency-rake",
      dependencies: [
        {
          "ecosystem" => "rubygems",
          "filepath" => "Gemfile",
          "kind" => "manifest",
          "dependencies" => [
            {
              "package_name" => "rails",
              "ecosystem" => "rubygems",
              "requirements" => "~> 8.1",
              "direct" => true,
              "kind" => "runtime",
              "optional" => false,
            },
          ],
        },
      ]
    )
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["projects:sync_dependencies"].execute }

    assert_equal ["rails"], project.project_dependencies.reload.pluck(:package_name)
    assert project.reload.dependencies_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "indexed: 1"
    assert_includes output, "dependencies: 1"
  end

  test "sync_repository_aliases indexes a bounded batch through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/current-name",
      repository: { "previous_names" => ["test/old-name"] }
    )
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_repository_aliases"].execute
    end

    assert_equal ["https://github.com/test/old-name"],
      project.repository_aliases.pluck(:url)
    assert project.reload.repository_aliases_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "indexed: 1"
    assert_includes output, "aliases: 1"
  end

  test "import_metadata_repositories creates and enqueues discovered repositories" do
    source = Project.create!(
      url: "https://github.com/metadata-test/metadata-source",
      science_score: 20,
      codemeta: {
        "codeRepository" => "https://github.com/metadata-test/metadata-target",
      }.to_json
    )
    MetadataRepositoryImporter.stubs(:configured_gitlab_hosts)
      .returns(["gitlab.com"])

    output, = capture_io do
      Rake::Task["projects:import_metadata_repositories"].execute
    end

    target = Project.find_by!(url: "https://github.com/metadata-test/metadata-target")
    assert_equal [[target.id]], SyncProjectWorker.jobs.map { |job| job["args"] }
    assert_includes output, "Metadata repository import:"
    assert_includes output, "created: 1"
    assert Project.exists?(source.id)
  end

  test "import_metadata_repositories skips repository previous names" do
    Project.create!(
      url: "https://github.com/metadata-test/current-target",
      repository: {
        "previous_names" => ["metadata-test/old-target"],
      }
    )
    Project.create!(
      url: "https://github.com/metadata-test/alias-source",
      science_score: 20,
      codemeta: {
        "codeRepository" => "https://github.com/metadata-test/old-target",
      }.to_json
    )
    MetadataRepositoryImporter.stubs(:configured_gitlab_hosts)
      .returns(["gitlab.com"])

    output, = capture_io do
      Rake::Task["projects:import_metadata_repositories"].execute
    end

    assert_includes output, "existing: 1"
    assert_includes output, "aliases: 1"
    assert_not Project.exists?(url: "https://github.com/metadata-test/old-target")
    assert_empty SyncProjectWorker.jobs
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
