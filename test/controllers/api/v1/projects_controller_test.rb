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

  test "GET show includes export URLs when citation_file is present" do
    cff_content = <<~CFF
      cff-version: 1.2.0
      title: "Test Project"
      authors:
        - family-names: "Doe"
          given-names: "John"
    CFF
    project = Project.create!(
      url: 'https://github.com/test/with-citation',
      name: 'Test Project',
      science_score: 50,
      citation_file: cff_content
    )

    get api_v1_project_url(project)

    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response['bibtex_url'].present?
    assert json_response['apalike_url'].present?
    assert_match(/export/, json_response['bibtex_url'])
    assert_match(/bibtex/, json_response['bibtex_url'])
    assert_match(/apalike/, json_response['apalike_url'])
  end

  test "GET show excludes export URLs when citation_file is absent" do
    project = Project.create!(
      url: 'https://github.com/test/without-citation',
      name: 'Test Project',
      science_score: 50
    )

    get api_v1_project_url(project)

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_nil json_response['bibtex_url']
    assert_nil json_response['apalike_url']
  end
end
