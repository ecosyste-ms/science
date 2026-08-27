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
end
