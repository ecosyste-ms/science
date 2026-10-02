require "test_helper"

class Api::V1::ProjectBulkLookupTest < ActionDispatch::IntegrationTest
  test "bulk lookup retains current and ambiguous former names without writes" do
    first = Project.create!(url: "https://github.com/Bulk/First", science_score: 30,
      repository: { "previous_names" => ["bulk/OldName"] })
    second = Project.create!(url: "https://github.com/bulk/second", science_score: 0,
      repository: { "previous_names" => ["bulk/OldName"] })
    [first, second].each { |project| ProjectRepositoryAliasIndexer.new(project).sync! }
    before_jobs = Sidekiq::Worker.jobs.deep_dup
    assert_no_difference ["Project.count", "ProjectRepositoryAlias.count"] do
      post "/api/v1/projects/bulk_lookup", params: { repository_urls: [
        "https://GitHub.com/Bulk/First.git", "https://github.com/bulk/OldName", "https://github.com/bulk/missing"
      ] }, as: :json
    end
    assert_response :success
    rows = response.parsed_body
    assert_equal first.id, rows.first.fetch("matches").sole.dig("project", "id")
    assert_equal "project.url", rows.first.fetch("matches").sole.fetch("source")
    assert_equal "https://github.com/bulk/first", rows.first.fetch("normalized_url")
    assert_equal [first.id, second.id], rows.second.fetch("matches").map { |match| match.dig("project", "id") }
    assert rows.second.fetch("matches").all? { |match| match.fetch("source") == "repository_alias" }
    assert_empty rows.last.fetch("matches")
    assert_equal before_jobs, Sidekiq::Worker.jobs
  end

  test "hidden projects do not appear through current or former URLs" do
    owner = Owner.create!(host: Host.create!(name: "Lookup GitHub"), login: "hidden", hidden: true)
    project = Project.create!(url: "https://github.com/bulk/hidden")
    project.repository_aliases.create!(url: "https://github.com/bulk/previous")
    project.update_columns(owner_id: owner.id)
    post "/api/v1/projects/bulk_lookup", params: { repository_urls: [project.url, "https://github.com/bulk/previous"] }, as: :json
    assert_response :success
    assert response.parsed_body.all? { |row| row.fetch("matches").empty? }
  end

  test "GitHub Pages and direct repository URLs resolve to the same indexed project" do
    project = Project.create!(url: "https://github.com/astro/photometry")
    project.repository_aliases.create!(url: "https://github.com/astro/former")
    post "/api/v1/projects/bulk_lookup", params: { repository_urls: [
      "https://Astro.github.io/photometry/docs/index.html", project.url,
      "https://astro.github.io/former/latest/"
    ] }, as: :json
    assert_response :success
    rows = response.parsed_body
    assert_equal [project.id], rows.flat_map { |row| row["matches"].map { |match| match.dig("project", "id") } }.uniq
    assert_equal project.url, rows.first["normalized_url"]
    assert_equal "repository_alias", rows.last["matches"].sole["source"]
  end

  test "bulk lookup rejects invalid and unbounded requests" do
    [nil, [], "https://github.com/bulk/repo", [nil], ["bad"], ["https://user:secret@github.com/bulk/repo"],
      ["x" * 2001], ["https://github.com/bulk/repo"] * 101].each do |urls|
      post "/api/v1/projects/bulk_lookup", params: { repository_urls: urls }, as: :json
      assert_response :bad_request
    end
    post "/api/v1/projects/bulk_lookup", params: { repository_urls: ["https://github.com/bulk/missing"] * 100 }, as: :json
    assert_response :success
    assert_equal 100, response.parsed_body.size
  end
end
