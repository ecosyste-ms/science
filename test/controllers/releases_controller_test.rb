require "test_helper"

class ReleasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(url: "https://gitlab.com/science/tool", name: "Tool")
    @tag = @project.releases.create!(tag_name: "v2", tag_sha: "a" * 40, tag_published_at: Time.utc(2025, 2, 1))
    @release = @project.releases.create!(tag_name: "v1", uuid: "release-1", name: "First release", published_at: Time.utc(2025, 1, 1))
    @undated = @project.releases.create!(tag_name: "undated")
  end

  test "web lists and details display tags and releases with separate dates" do
    get project_releases_url(@project)
    assert_response :success
    assert_equal [@tag.id, @release.id, @undated.id], assigns(:releases).map(&:id)
    assert_includes response.body, "Tag dated"
    assert_includes response.body, "Date unavailable"

    get project_release_url(@project, @tag)
    assert_response :success
    assert_includes response.body, @tag.tag_sha
    assert_select "h1", "v2"
  end

  test "API lists and details preserve tag and forge fields" do
    get api_v1_project_releases_url(@project)
    assert_response :success
    assert_equal [@tag.id, @release.id, @undated.id], response.parsed_body.map { |row| row["id"] }
    assert_equal false, response.parsed_body.first["forge_release"]
    assert_nil response.parsed_body.first["published_at"]

    get api_v1_project_release_url(@project, @release)
    assert_response :success
    assert_equal true, response.parsed_body["forge_release"]
    assert_equal "First release", response.parsed_body["name"]
  end

  test "nested detail routes require the correct parent project" do
    other = Project.create!(url: "https://gitlab.com/science/other")

    get project_release_url(other, @tag)
    assert_response :not_found
    get api_v1_project_release_url(other, @tag)
    assert_response :not_found
  end

  test "hidden projects are excluded from web and API releases" do
    host = Host.create!(name: "GitLab")
    owner = Owner.create!(host: host, login: "science", hidden: true)
    @project.update_columns(owner_id: owner.id)

    get releases_url
    assert_response :success
    assert_empty assigns(:releases)
    get project_releases_url(@project)
    assert_response :not_found
    get api_v1_project_releases_url(@project)
    assert_response :not_found
    get api_v1_project_release_url(@project, @tag)
    assert_response :not_found
  end
end
