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

  test "GET show includes arXiv IDs and ORCIDs" do
    project = Project.create!(
      url: 'https://github.com/test/with-identifiers',
      readme: <<~README,
        Paper: https://arxiv.org/abs/2202.01037v2?utm_source=readme
        Author: https://orcid.org/0000-0002-0088-0058
      README
      codemeta: '{"author":{"@id":"https://orcid.org/0000-0003-0166-248x"}}'
    )

    get api_v1_project_url(project)

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal ['2202.01037'], json_response['arxiv_ids']
    assert_equal [
      '0000-0002-0088-0058',
      '0000-0003-0166-248X',
    ], json_response['orcids']
  end

  test "GET show includes several ranked OpenAlex fields" do
    project = Project.create!(
      url: "https://github.com/test/with-fields",
      name: "Scientific Toolkit",
      science_score: 70
    )
    engineering = Field.create!(
      name: "Engineering",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/22"
    )
    computer_science = Field.create!(
      name: "Computer Science",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/17"
    )
    legacy = Field.create!(name: "Legacy Field", domain: "physical_sciences")
    ProjectField.create!(project: project, field: engineering, confidence_score: 0.62)
    ProjectField.create!(project: project, field: computer_science, confidence_score: 0.84)
    ProjectField.create!(project: project, field: legacy, confidence_score: 0.99)

    get api_v1_project_url(project)

    assert_response :success
    fields = JSON.parse(response.body).fetch("fields")
    assert_equal [
      "https://openalex.org/fields/17",
      "https://openalex.org/fields/22",
    ], fields.map { |field| field.fetch("id") }
    assert_equal ["Computer Science", "Engineering"], fields.map { |field| field.fetch("name") }
    assert_equal [0.84, 0.62], fields.map { |field| field.fetch("score") }
    assert fields.all? { |field| field.fetch("domain") == "Physical Sciences" }
  end
end
