require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "index renders without stats when the cache is empty" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Project.expects(:stats_summary).never
    ProjectExternalSoftwareRecord.expects(:scientific_source_counts).never

    get root_url

    assert_response :success
    assert_nil assigns(:stats)
    assert_select "a[href='#{packages_path}']", text: "Packages"
    assert_select "a[href='#{packages_path}'] + a[href='#{models_path}']", text: "Models"
  end

  test "index shows cached stats without calculating them" do
    stats = {
      total_projects: 123,
      scientific_projects: 45,
      institutional_owners: 6,
      joss_projects: 7,
      top_languages: [],
      external_sources: [["wikidata", 1234], ["biotools", 56], ["ascl", 12], ["swmath", 8]]
    }
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("homepage_stats", stats)
    Rails.stubs(:cache).returns(cache)
    Project.expects(:stats_summary).never
    ProjectExternalSoftwareRecord.expects(:scientific_source_counts).never

    get root_url

    assert_response :success
    assert_equal stats, assigns(:stats)
    assert_select ".stat-card-number-positive", text: "123"
    assert_select ".card-title", text: "External Sources"
    assert_select ".list-group-item", text: /Wikidata\s+1,234/
    assert_select ".list-group-item", text: /bio.tools\s+56/
    assert_select ".list-group-item", text: /ASCL\s+12/
    assert_select ".list-group-item", text: /swMATH\s+8/
  end

  test "data completeness shows cached BibTeX coverage and tolerates older cached stats" do
    stats = { total_projects: 100, top_languages: [["Ruby", 50]], projects_with_bibtex: 12 }
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    cache.write("homepage_stats", stats)
    Project.expects(:stats_summary).never

    get root_url

    assert_response :success
    assert_select "#bibtex-completeness-label", text: "With BibTeX"
    assert_select "progress[value='12'][max='100'][aria-labelledby='bibtex-completeness-label']"
    assert_select "div", text: /With BibTeX\s+12 \/ 100/

    cache.write("homepage_stats", stats.except(:projects_with_bibtex))
    get root_url
    assert_response :success
    assert_select "#bibtex-completeness-label", count: 0
  end
end
