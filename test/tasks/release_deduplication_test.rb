require "test_helper"
require "rake"

class ReleaseDeduplicationTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:deduplicate_releases")
    @saved_env = ENV.to_h.slice("LIMIT", "AFTER_ID", "DRY_RUN")
    %w[LIMIT AFTER_ID DRY_RUN].each { |key| ENV.delete(key) }
    @project = Project.create!(url: "https://gitlab.com/science/duplicates")
  end

  teardown do
    %w[LIMIT AFTER_ID DRY_RUN].each { |key| ENV.delete(key) }
    ENV.update(@saved_env)
  end

  test "defaults to a bounded preview and preserves the original row when applied" do
    keeper = @project.releases.create!(tag_name: "v1", uuid: "1", body: "Notes")
    duplicate = @project.releases.create!(tag_name: "v1", uuid: "1", body: "Notes", last_synced_at: Time.current)
    2.times { @project.releases.create!(tag_name: "v2", uuid: "2") }
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["projects:deduplicate_releases"].execute }

    assert_includes output, "removable: 1"
    assert_includes output, "last_id: #{keeper.id}"
    assert_equal 4, @project.releases.count

    ENV["DRY_RUN"] = "false"
    capture_io { Rake::Task["projects:deduplicate_releases"].execute }
    assert Release.exists?(keeper.id)
    assert_not Release.exists?(duplicate.id)
    assert_equal 3, @project.releases.count

    ENV["AFTER_ID"] = keeper.id.to_s
    capture_io { Rake::Task["projects:deduplicate_releases"].execute }
    assert_equal 2, @project.releases.count
  end

  test "never merges conflicting UUIDs or different stored release metadata" do
    2.times { @project.releases.create!(tag_name: "v1", uuid: "1") }
    @project.releases.create!(tag_name: "v1", uuid: "different")
    @project.releases.create!(tag_name: "v2", uuid: "2", body: "Original notes")
    @project.releases.create!(tag_name: "v2", uuid: "2", body: "Changed notes")
    ENV["DRY_RUN"] = "false"

    output, = capture_io { Rake::Task["projects:deduplicate_releases"].execute }

    assert_includes output, "conflicts: 1"
    assert_includes output, "differing_payloads: 1"
    assert_equal 5, @project.releases.count
  end
end
