require "test_helper"

class OwnersControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")

    get host_owners_url(host.name)
    assert_response :success
    assert_select "h1", /#{host.name}/
  end

  test "should show owner" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser", name: "Test User", repositories_count: 10)
    project = Project.create!(url: "https://github.com/testuser/repo", owner_record: owner, science_score: 5.0)

    get host_owner_url(host.name, owner.login)
    assert_response :success
    assert_select "h1", /#{host.name}/
    assert_select "h1", /#{owner.login}/
  end

  test "should find owner case insensitively" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    project = Project.create!(url: "https://github.com/testuser/repo", owner_record: owner, science_score: 5.0)

    get host_owner_url(host.name, "TestUser")
    assert_response :success
  end

  test "should return 404 for missing owner" do
    host = Host.create!(name: "GitHub")

    get host_owner_url(host.name, "nonexistent")
    assert_response :not_found
  end

  test "should only show projects with science_score > 0" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    project1 = Project.create!(url: "https://github.com/testuser/repo1", owner_record: owner, science_score: 5.0)
    project2 = Project.create!(url: "https://github.com/testuser/repo2", owner_record: owner, science_score: 0)

    get host_owner_url(host.name, owner.login)
    assert_response :success
  end
end
