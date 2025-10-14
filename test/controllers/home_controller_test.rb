require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get root_url
    assert_response :success
  end

  test "index shows stats" do
    get root_url
    assert_response :success
    assert_not_nil assigns(:stats)
  end
end
