require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "index renders without stats when the cache is empty" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Project.expects(:stats_summary).never

    get root_url

    assert_response :success
    assert_nil assigns(:stats)
    assert_select "a[href='#{packages_path}']", text: "Packages"
  end

  test "index shows cached stats without calculating them" do
    stats = {
      total_projects: 123,
      scientific_projects: 45,
      institutional_owners: 6,
      joss_projects: 7,
      top_languages: []
    }
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("homepage_stats", stats)
    Rails.stubs(:cache).returns(cache)
    Project.expects(:stats_summary).never

    get root_url

    assert_response :success
    assert_equal stats, assigns(:stats)
    assert_select ".stat-card-number-positive", text: "123"
  end
end
