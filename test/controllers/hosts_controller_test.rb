require "test_helper"

class HostsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get hosts_url
    assert_response :success
  end

  test "should show host" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    get host_url(host.name)
    assert_response :success
    assert_select "h1", /#{host.name}/
  end

  test "show lists projects from visible owners only" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    hidden_owner = Owner.create!(host: host, login: "hidden-owner")
    shown_owner = Owner.create!(host: host, login: "shown-owner")
    Project.create!(host: host, owner_record: hidden_owner, url: "https://github.com/hidden-owner/secret", name: "secret-project", science_score: 50)
    Project.create!(host: host, owner_record: shown_owner, url: "https://github.com/shown-owner/public", name: "public-project", science_score: 50)
    hidden_owner.update!(hidden: true)

    get host_url(host.name)

    assert_response :success
    assert_includes response.body, "public-project"
    assert_not_includes response.body, "secret-project"
  end

  test "should handle host with dots in name" do
    host = Host.create!(name: "git.example.com", url: "https://git.example.com")
    get host_url(host.name)
    assert_response :success
  end

  test "should return 404 for missing host" do
    get host_url("nonexistent")
    assert_response :not_found
  end

  test "show falls back to science_score for unknown sort column" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    get host_url(host.name), params: { sort: 'pg_sleep(1)', order: 'nope' }
    assert_response :success
    sql = assigns(:scope).to_sql
    assert_match 'ORDER BY science_score DESC NULLS LAST', sql
    assert_no_match 'pg_sleep', sql
  end
end
