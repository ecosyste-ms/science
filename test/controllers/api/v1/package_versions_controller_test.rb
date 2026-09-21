require "test_helper"

class Api::V1::PackageVersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(url: "https://github.com/science/tool", science_score: 50)
    registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org",
      ecosystem: "pypi", purl_type: "pypi")
    @package = Package.create!(package_registry: registry, name: "tool", published_by_project: @project)
    @older = @package.package_versions.create!(ecosystems_id: 1, number: "1.0",
      published_at: 2.days.ago, fetched_at: Time.current)
    @newer = @package.package_versions.create!(ecosystems_id: 2, number: "2.0",
      published_at: 1.day.ago, fetched_at: Time.current, immutable: true, licenses: "MIT")
    @undated = @package.package_versions.create!(ecosystems_id: 3, number: "3.0", fetched_at: Time.current)
  end

  test "API paginates version history with stable date ordering and exposes source metadata" do
    get api_v1_package_versions_url(@package), params: { per_page: 2 }

    assert_response :success
    assert_equal [@newer.id, @older.id], response.parsed_body.map { |row| row["id"] }
    assert_includes response.headers["Link"], 'rel="next"'

    get api_v1_package_versions_url(@package), params: { per_page: 2, page: 2 }
    assert_response :success
    assert_equal [@undated.id], response.parsed_body.map { |row| row["id"] }

    get api_v1_package_version_url(@package, @newer)
    assert_response :success
    assert_equal 2, response.parsed_body["ecosystems_id"]
    assert_equal "2.0", response.parsed_body["number"]
    assert_equal true, response.parsed_body["immutable"]
    assert_equal "MIT", response.parsed_body["licenses"]
    assert_nil response.parsed_body["release_id"]
    assert_nil response.parsed_body["release_match_method"]
  end

  test "equal dates are ordered by descending local ID" do
    @older.update!(published_at: @newer.published_at)

    get api_v1_package_versions_url(@package)

    assert_response :success
    assert_equal [@newer.id, @older.id, @undated.id], response.parsed_body.map { |row| row["id"] }
  end

  test "detail routes require the correct package" do
    other = Package.create!(package_registry: @package.package_registry, name: "other", published_by_project: @project)

    get api_v1_package_version_url(other, @newer)

    assert_response :not_found
  end

  test "packages without a visible publisher are excluded" do
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "science", hidden: true)
    @project.update_columns(owner_id: owner.id)

    get api_v1_package_versions_url(@package)
    assert_response :not_found
    get api_v1_package_version_url(@package, @newer)
    assert_response :not_found

    @package.update!(published_by_project: nil)
    get api_v1_package_versions_url(@package)
    assert_response :not_found
  end

  test "deleting a release preserves its package version without a dangling API match" do
    release = @project.releases.create!(tag_name: "v2.0")
    @newer.update!(release: release, release_match_method: "packages_related_tag")
    release.destroy!

    get api_v1_package_version_url(@package, @newer)

    assert_response :success
    assert_nil response.parsed_body["release_id"]
    assert_nil response.parsed_body["release_match_method"]
  end
end
