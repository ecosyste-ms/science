require "test_helper"
require "rake"

class SoftwareSearchIndexTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("search_seeds:index")
    @environment = ENV.to_h.slice("LIMIT", "AFTER_ID")
  end

  teardown do
    %w[LIMIT AFTER_ID].each { |key| ENV[key] = @environment[key] }
  end

  test "indexes existing projects in bounded resumable batches without changing source timestamps" do
    first = Project.create!(url: "https://github.com/search/first", name: "First", science_score: 50)
    second = Project.create!(url: "https://github.com/search/second", name: "Second", science_score: 50)
    third = Project.create!(url: "https://github.com/search/third", name: "Third", science_score: 50)
    timestamp = second.updated_at
    ENV["LIMIT"] = "1"
    ENV["AFTER_ID"] = first.id.to_s
    Rake::Task["search_seeds:index"].reenable
    output, = capture_io { Rake::Task["search_seeds:index"].invoke }
    assert_equal({ "indexed" => 1, "last_project_id" => second.id }, JSON.parse(output))
    assert_equal ["second"], second.reload.search_identifiers.fetch("name")
    assert_equal timestamp, second.updated_at
    assert_nil first.reload.search_indexed_at
    assert_nil third.reload.search_indexed_at
  end
end
