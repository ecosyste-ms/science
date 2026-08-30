require "test_helper"

class FieldsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @computer_science = Field.create!(
      name: "Computer Science",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/17"
    )
    @engineering = Field.create!(
      name: "Engineering",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/22"
    )
    @legacy_field = Field.create!(
      name: "Legacy Demo Field",
      domain: "physical_sciences"
    )
    create_topic(
      openalex_id: "https://openalex.org/T1",
      name: "Software Engineering",
      field: @computer_science,
      subfield_id: "https://openalex.org/subfields/1712",
      subfield_name: "Software"
    )
    create_topic(
      openalex_id: "https://openalex.org/T2",
      name: "Control Engineering",
      field: @engineering,
      subfield_id: "https://openalex.org/subfields/2207",
      subfield_name: "Control and Systems Engineering"
    )
    @project_one = Project.create!(
      url: "https://github.com/test/algorithm-toolkit",
      name: "Algorithm Toolkit",
      description: "Algorithms for scientific computing",
      keywords: %w[algorithms computing],
      science_score: 72
    )
    @project_two = Project.create!(
      url: "https://github.com/test/control-simulator",
      name: "Control Simulator",
      description: "Control systems simulation",
      keywords: %w[control simulation],
      science_score: 64
    )
    @non_scientific_project = Project.create!(
      url: "https://github.com/test/non-scientific",
      name: "Non-scientific Project",
      science_score: Project::SCIENCE_SCORE_THRESHOLD - 1
    )
    ProjectField.create!(
      project: @project_one,
      field: @computer_science,
      confidence_score: 0.81,
      match_signals: { "matched_terms" => %w[algorithm computing] }
    )
    ProjectField.create!(
      project: @project_one,
      field: @engineering,
      confidence_score: 0.46,
      match_signals: { "matched_terms" => %w[simulation] }
    )
    ProjectField.create!(
      project: @project_two,
      field: @engineering,
      confidence_score: 0.73,
      match_signals: { "matched_terms" => %w[control simulation] }
    )
    ProjectField.create!(
      project: @project_two,
      field: @legacy_field,
      confidence_score: 0.99
    )
    ProjectField.create!(
      project: @non_scientific_project,
      field: @engineering,
      confidence_score: 1.0
    )
  end

  test "index lists OpenAlex fields and classification counts" do
    get fields_url

    assert_response :success
    assert_select "h1", text: "Scientific Fields"
    assert_select "a[href='#{field_path(@computer_science)}']", text: @computer_science.name
    assert_select "a[href='#{field_path(@engineering)}']", text: @engineering.name
    assert_select "a[href='/domains/physical-sciences']", text: "Physical Sciences"
    assert_no_match @legacy_field.name, response.body
    assert_no_match @non_scientific_project.name, response.body
    assert_match "2 projects", response.body
    assert_match "Active Topics", response.body
    assert_match "Multi-field Projects", response.body
  end

  test "show resolves a field slug and ranks projects by classifier score" do
    get field_url(@engineering)

    assert_response :success
    assert_select "h1", text: @engineering.name
    assert_match "Field ID:", response.body
    assert_match "22", response.body
    assert_match "Control and Systems Engineering", response.body
    assert_no_match "https://openalex.org/subfields/2207", response.body
    assert_select "a[href='/domains/physical-sciences']", text: "Physical Sciences"
    assert_operator response.body.index(@project_two.name), :<, response.body.index(@project_one.name)
    assert_match "score 0.730", response.body
    assert_match "Control", response.body
    assert_match "Also ranked in:", response.body
    assert_select "a[href='#{field_path(@computer_science)}']", text: @computer_science.name
  end

  test "show lists related OpenAlex fields and their project counts" do
    get field_url(@computer_science)

    assert_response :success
    assert_match "Related Fields", response.body
    assert_select "a[href='#{field_path(@engineering)}']", text: @engineering.name
    assert_match "(2 projects)", response.body
  end

  test "domain lists its OpenAlex fields and each classified project once" do
    get open_alex_domain_url("physical-sciences")

    assert_response :success
    assert_select "h1", text: "Physical Sciences"
    assert_select "a[href='#{field_path(@computer_science)}']", text: @computer_science.name
    assert_select "a[href='#{field_path(@engineering)}']", text: @engineering.name
    assert_select "[data-project-id='#{@project_one.id}']", count: 1
    assert_select "[data-project-id='#{@project_two.id}']", count: 1
    assert_no_match @legacy_field.name, response.body
    assert_no_match @non_scientific_project.name, response.body
    assert_operator response.body.index(@project_one.name), :<, response.body.index(@project_two.name)
    assert_match "score 0.810", response.body
  end

  test "domain rejects an unknown OpenAlex domain slug" do
    get open_alex_domain_url("not-a-domain")
    assert_response :not_found
  end

  test "show returns 404 for a legacy field ID" do
    get field_url(@legacy_field.id)

    assert_response :not_found
  end

  test "show rejects an unknown field slug" do
    get field_url("not-a-field")
    assert_response :not_found
  end

  test "show escapes project keywords" do
    @project_one.update!(keywords: ["<script>alert(1)</script>"])

    get field_url(@computer_science)

    assert_response :success
    assert_no_match "<script>alert", response.body
  end

  def create_topic(openalex_id:, name:, field:, subfield_id:, subfield_name:)
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: name,
      subfield_id: subfield_id,
      subfield_name: subfield_name,
      field_id: field.openalex_id,
      field_name: field.name,
      domain_id: "https://openalex.org/domains/3",
      domain_name: field.domain
    )
  end
end
