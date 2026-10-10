require "test_helper"

class ProjectFiltersTest < ActionDispatch::IntegrationTest
  setup do
    create_research_organization_domain("research.example")
    ResearchOrganizationDomainMatcher.reset_cache!
    host = Host.create!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(host: host, login: "lab", kind: "organization", website: "https://research.example")
    @project = Project.create!(
      url: "https://github.com/lab/science",
      name: "Science tool",
      science_score: 80,
      owner_record: owner,
      keywords: %w[science biology],
      citation_file: "cff-version: 1.2.0",
      joss_metadata: { "doi" => "10.21105/joss.00001" },
      repository: {
        "owner" => "lab", "language" => "Python",
        "metadata" => { "files" => { "codemeta" => "codemeta.json", "zenodo" => ".zenodo.json" } }
      }
    )
    @filters = { "keyword" => "science", "language" => "Python", "owner" => "lab", "research_organization" => "true" }
  end

  teardown do
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "all shared listings show removable filters and preserve their route and sort" do
    [projects_path, joss_projects_path, codemeta_projects_path, citation_projects_path, zenodo_projects_path].each do |path|
      get path, params: @filters.merge("sort" => "score", "order" => "asc", "page" => "1")

      assert_response :success
      assert_select "#project_#{@project.id}"
      assert_select "nav[aria-label='Active project filters']" do
        { "keyword" => "Keyword: science", "language" => "Language: Python", "owner" => "Owner: lab",
          "research_organization" => "Research organizations" }.each do |key, label|
          assert_select "a[aria-label='Remove #{label} filter']", count: 1 do |links|
            uri = URI.parse(links.first["href"])
            assert_equal path, uri.path
            assert_equal @filters.except(key).merge("sort" => "score", "order" => "asc"), Rack::Utils.parse_nested_query(uri.query)
          end
        end
        assert_select "a", text: "Clear filters", count: 1 do |links|
          uri = URI.parse(links.first["href"])
          assert_equal path, uri.path
          assert_equal({ "sort" => "score", "order" => "asc" }, Rack::Utils.parse_nested_query(uri.query))
        end
      end
    end
  end

  test "sorting toggling and keyword links preserve other filters and reset pagination" do
    get projects_path, params: @filters.merge("sort" => "score", "order" => "asc", "page" => "1")

    assert_response :success
    assert_select ".dropdown-menu a", text: "Recently synced" do |links|
      assert_equal @filters.merge("sort" => "last_synced_at", "order" => "desc"), Rack::Utils.parse_nested_query(URI.parse(links.first["href"]).query)
      get links.first["href"]
    end
    assert_response :success
    assert_select "#project_#{@project.id}"
    assert_select "a[aria-pressed='true']", text: "Research organizations" do |links|
      assert_equal @filters.except("research_organization").merge("sort" => "last_synced_at", "order" => "desc"), Rack::Utils.parse_nested_query(URI.parse(links.first["href"]).query)
      get links.first["href"]
    end
    assert_response :success
    assert_select "a[aria-pressed='false']", text: "Research organizations" do |links|
      assert_equal @filters.merge("sort" => "last_synced_at", "order" => "desc"), Rack::Utils.parse_nested_query(URI.parse(links.first["href"]).query)
    end
    assert_select "#project_#{@project.id} a", text: "biology" do |links|
      assert_equal @filters.except("research_organization").merge("keyword" => "biology", "sort" => "last_synced_at", "order" => "desc"), Rack::Utils.parse_nested_query(URI.parse(links.first["href"]).query)
      get links.first["href"]
    end
    assert_response :success
    assert_select "#project_#{@project.id}"
    assert_select "a[aria-label='Remove Keyword: biology filter']"
  end

  test "empty filtered results retain controls and can be cleared" do
    get joss_projects_path, params: { keyword: "missing", language: "Python", page: "2" }

    assert_response :success
    assert_select ".listing", count: 0
    assert_select "[role='status']", text: "No projects match these filters."
    assert_select "a[aria-label='Remove Keyword: missing filter']" do |links|
      get links.first["href"]
    end
    assert_response :success
    assert_select "#project_#{@project.id}"
    assert_select "nav[aria-label='Active project filters'] a", text: "Clear filters" do |links|
      assert_equal joss_projects_path, links.first["href"]
      get links.first["href"]
    end
    assert_response :success
    assert_select "#project_#{@project.id}"
    assert_select "nav[aria-label='Active project filters']", count: 0
  end

  test "unfiltered listing has no active filter controls" do
    get projects_path

    assert_response :success
    assert_select "nav[aria-label='Active project filters']", count: 0
    assert_select "#project_#{@project.id}"
  end
end
