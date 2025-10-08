require 'test_helper'

class Api::V1::ProjectsControllerTest < ActionDispatch::IntegrationTest
  test "GET names returns unique package and project names" do
    Project.create!(
      url: 'https://github.com/test/project1',
      name: 'Climate Tool',
      science_score: 50,
      packages: [{ 'name' => 'climate-pkg' }, { 'name' => 'Weather-Lib' }]
    )
    Project.create!(
      url: 'https://github.com/test/project2',
      name: 'Weather System',
      science_score: 75,
      packages: [{ 'name' => 'weather-lib' }]
    )

    Rails.cache.clear
    get names_api_v1_projects_url

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_kind_of Array, json_response
    assert_includes json_response, 'climate-pkg'
    assert_includes json_response, 'weather-lib'
    assert_includes json_response, 'climate tool'
    assert_includes json_response, 'weather system'
  end

  test "GET names excludes projects with zero science score" do
    Project.create!(
      url: 'https://github.com/test/scientific',
      name: 'Scientific Project',
      science_score: 50,
      packages: [{ 'name' => 'science-pkg' }]
    )
    Project.create!(
      url: 'https://github.com/test/nonscientific',
      name: 'Non-Scientific Project',
      science_score: 0,
      packages: [{ 'name' => 'nonscience-pkg' }]
    )

    Rails.cache.clear
    get names_api_v1_projects_url

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_includes json_response, 'science-pkg'
    assert_not_includes json_response, 'nonscience-pkg'
  end
end
