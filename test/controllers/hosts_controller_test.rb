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

  test "should handle host with dots in name" do
    host = Host.create!(name: "git.example.com", url: "https://git.example.com")
    get host_url(host.name)
    assert_response :success
  end

  test "should return 404 for missing host" do
    get host_url("nonexistent")
    assert_response :not_found
  end
end
