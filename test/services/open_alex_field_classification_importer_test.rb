require "test_helper"

class OpenAlexFieldClassificationImporterTest < ActiveSupport::TestCase
  test "materializes ranked OpenAlex fields for scientific projects" do
    create_topic(
      openalex_id: "https://openalex.org/T-software",
      name: "Software Engineering Algorithms",
      keywords: ["Algorithms"],
      field_id: "17",
      field_name: "Computer Science",
      domain_name: "Physical Sciences"
    )
    create_topic(
      openalex_id: "https://openalex.org/T-control",
      name: "Control Systems Simulation",
      keywords: ["Control Systems"],
      field_id: "22",
      field_name: "Engineering",
      domain_name: "Physical Sciences"
    )
    inactive = create_topic(
      openalex_id: "https://openalex.org/T-inactive",
      name: "Inactive Topic",
      keywords: ["Inactive"],
      field_id: "99",
      field_name: "Inactive Field",
      domain_name: "Inactive Domain",
      active: false
    )
    project = Project.create!(
      url: "https://github.com/test/control-algorithms",
      name: "Control Algorithms",
      description: "Algorithms and simulation for control systems",
      keywords: %w[algorithms control simulation],
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    excluded = Project.create!(
      url: "https://github.com/test/non-scientific-control",
      name: "Control Algorithms",
      keywords: %w[algorithms control],
      science_score: Project::SCIENCE_SCORE_THRESHOLD - 1
    )
    legacy_field = Field.create!(name: "Computer Science", domain: "computer_science")
    ProjectField.create!(
      project: project,
      field: legacy_field,
      confidence_score: 0.99,
      match_signals: { "keywords" => 1.0 }
    )
    excluded_legacy_classification = ProjectField.create!(
      project: excluded,
      field: legacy_field,
      confidence_score: 0.98
    )
    messages = []

    result = OpenAlexFieldClassificationImporter.sync!(
      progress: ->(message) { messages << message }
    )

    assert_equal 2, result[:fields]
    assert_equal 1, result[:projects]
    assert_equal 1, result[:classified_projects]
    assert_equal 2, result[:classifications]
    assert_equal "17", legacy_field.reload.openalex_id
    assert_equal "Physical Sciences", legacy_field.domain
    assert_empty legacy_field.keywords
    rankings = project.reload.open_alex_fields_with_scores
    assert_equal %w[17 22], rankings.map { |field, _| field.openalex_id }.sort
    assert_equal rankings.map(&:last).sort.reverse, rankings.map(&:last)
    matched_terms = project.project_fields.flat_map do |classification|
      classification.match_signals.fetch("matched_terms")
    end
    assert_includes matched_terms, "algorithms"
    assert_includes matched_terms, "control"
    assert_empty excluded.project_fields
    assert_not ProjectField.exists?(excluded_legacy_classification.id)
    assert_not Field.exists?(openalex_id: inactive.field_id)
    assert_equal ["OpenAlex field projects classified: 1"], messages
  end

  test "a limited rebuild replaces classifications only for selected projects" do
    create_topic(
      openalex_id: "https://openalex.org/T-limited",
      name: "Genome Analysis",
      keywords: ["Genomics"],
      field_id: "13",
      field_name: "Biochemistry, Genetics and Molecular Biology",
      domain_name: "Life Sciences"
    )
    projects = 2.times.map do |index|
      Project.create!(
        url: "https://github.com/test/genome-#{index}",
        name: "Genome Analysis",
        keywords: %w[genomics],
        science_score: Project::SCIENCE_SCORE_THRESHOLD
      )
    end
    field = Field.create!(
      name: "Existing OpenAlex Field",
      domain: "Life Sciences",
      openalex_id: "88"
    )
    untouched = ProjectField.create!(
      project: projects.last,
      field: field,
      confidence_score: 0.5
    )

    OpenAlexFieldClassificationImporter.sync!(scope: Project.where(id: projects.first.id))

    assert projects.first.project_fields.reload.any?
    assert ProjectField.exists?(untouched.id)
  end

  def create_topic(
    openalex_id:,
    name:,
    keywords:,
    field_id:,
    field_name:,
    domain_name:,
    active: true
  )
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: name,
      keywords: keywords,
      subfield_id: "#{field_id}01",
      subfield_name: "#{field_name} Subfield",
      field_id: field_id,
      field_name: field_name,
      domain_id: "1",
      domain_name: domain_name,
      active: active
    )
  end
end
