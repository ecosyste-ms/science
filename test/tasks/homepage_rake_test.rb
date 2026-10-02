require "test_helper"
require "rake"

class HomepageRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("homepage:refresh")
    Rake::Task["homepage:refresh"].reenable
  end

  test "refresh calculates and caches homepage stats" do
    stats = { total_projects: 123, top_languages: [["Ruby", 50]] }
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    Project.expects(:stats_summary).returns(stats)

    output, = capture_io { Rake::Task["homepage:refresh"].invoke }

    assert_equal stats, cache.read("homepage_stats")
    assert_includes output, "Cached homepage stats for 123 projects"
  end

  test "refresh counts distinct scientific projects per source and caches the breakdown" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    matched = Project.create!(url: "https://github.com/coverage/matched", science_score: 40)
    other = Project.create!(url: "https://github.com/coverage/other", science_score: 40)
    non_scientific = Project.create!(url: "https://github.com/coverage/non-scientific", science_score: 0)
    hidden = Project.create!(url: "https://github.com/coverage/hidden", science_score: 40)
    owner = Owner.create!(host: Host.create!(name: "Source Coverage"), login: "hidden", hidden: true)
    hidden.update_columns(owner_id: owner.id)
    entries = [
      [matched, "wikidata", "ok", "matched", Time.current],
      [matched, "wikidata", "ok", "matched", Time.current],
      [other, "wikidata", "error", "matched", Time.current],
      [matched, "other", "ok", "matched", Time.current],
      [non_scientific, "wikidata", "ok", "matched", Time.current],
      [hidden, "wikidata", "ok", "matched", Time.current],
      [other, "other", "ok", "ambiguous", Time.current],
      [other, "other", "missing", "matched", Time.current],
      [other, "other", "error", "matched", nil],
    ]
    entries.each_with_index do |(project, source, status, match_status, retrieved_at), index|
      record = ExternalSoftwareRecord.create!(source: source, identifier: "Q#{index + 1}", status: status,
        retrieved_at: retrieved_at, next_refresh_at: 1.day.from_now)
      project.project_external_software_records.create!(external_software_record: record,
        relationship: "source_code_repository", match_status: match_status)
    end

    capture_io { Rake::Task["homepage:refresh"].invoke }

    assert_equal [["wikidata", 2], ["other", 1]], cache.read("homepage_stats").fetch(:external_sources)
  end
end
