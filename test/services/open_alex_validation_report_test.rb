require "test_helper"
require "csv"
require "stringio"

class OpenAlexValidationReportTest < ActiveSupport::TestCase
  test "exports one comparison per project and OpenAlex work without saving predictions" do
    project = Project.create!(
      url: "https://github.com/test/validation-report",
      name: "Genome Toolkit",
      description: "Genomics and sequence analysis",
      keywords: %w[genomics sequencing]
    )
    topic = create_topic(
      openalex_id: "https://openalex.org/T10001",
      name: "Genomics and Sequence Analysis",
      keywords: ["Genomics", "Sequence Analysis"]
    )
    create_topic(
      openalex_id: "https://openalex.org/T10002",
      name: "Fluid Mechanics",
      keywords: ["Turbulence", "Fluid Flow"],
      subfield_id: "2202",
      subfield_name: "Mechanics",
      field_id: "22",
      field_name: "Engineering"
    )
    create_assignment(project, topic, source: "joss_doi")
    create_assignment(project, topic, source: "readme_doi")
    assignment_count = ProjectOpenAlexTopic.count
    io = StringIO.new

    result = OpenAlexValidationReport.new(scope: Project.where(id: project.id)).generate(io: io)

    rows = CSV.parse(io.string, headers: true)
    assert_equal 1, rows.length
    assert_equal "joss_doi|readme_doi", rows.first["sources"]
    assert_equal topic.openalex_id, rows.first["label_topic_id"]
    assert_equal topic.openalex_id, rows.first["work_topic_ids"]
    assert_equal topic.openalex_id, rows.first["predicted_topic_id"]
    assert_equal "true", rows.first["exact_topic_match"]
    assert_equal "true", rows.first["exact_field_match"]
    assert_equal({
      labels: 1,
      predicted_labels: 1,
      exact_topic_matches: 1,
      top_5_topic_matches: 1,
      exact_subfield_matches: 1,
      top_5_subfield_matches: 1,
      exact_field_matches: 1,
      top_5_field_matches: 1,
      exact_domain_matches: 1,
      projects: 1,
      predicted_projects: 1,
    }, result[:overall])
    assert_equal 1, result.dig(:by_source, "joss_doi|readme_doi", :labels)
    assert_equal 1, result.dig(:by_label_score, ">=0.95", :exact_topic_matches)
    assert_equal assignment_count, ProjectOpenAlexTopic.count
  end

  test "normalizes OpenAlex hierarchy IDs when comparing predictions" do
    predicted_topic = create_topic(
      openalex_id: "https://openalex.org/T20001",
      name: "Software Engineering",
      subfield_id: "https://openalex.org/subfields/1712",
      field_id: "https://openalex.org/fields/17",
      domain_id: "https://openalex.org/domains/3"
    )
    label = create_topic(
      openalex_id: "T20001",
      name: "Software Engineering Label",
      subfield_id: "1712",
      field_id: "17",
      domain_id: "3"
    )
    prediction = OpenAlexTopicClassifier::Prediction.new(topic: predicted_topic)

    matches = OpenAlexValidationReport.new.matches_for([prediction], [label])

    assert matches.values.all?
  end

  test "compares predictions with every topic stored for an OpenAlex work" do
    project = Project.create!(url: "https://github.com/test/all-work-topics")
    primary = create_topic(
      openalex_id: "https://openalex.org/T-primary",
      name: "Clinical Medicine",
      subfield_id: "2701",
      subfield_name: "Medicine",
      field_id: "27",
      field_name: "Medicine",
      domain_id: "4",
      domain_name: "Health Sciences"
    )
    additional = create_topic(
      openalex_id: "https://openalex.org/T-additional",
      name: "Software Engineering"
    )
    create_assignment(project, primary, source: "readme_doi")
    create_assignment(
      project,
      additional,
      source: "readme_doi",
      primary_topic: false,
      score: 0.72
    )
    prediction = OpenAlexTopicClassifier::Prediction.new(
      topic: additional,
      score: 0.8,
      matched_terms: ["software_engineering"]
    )
    classifier = mock("classifier")
    classifier.expects(:classify_project).with(project, limit: 5).returns([prediction])
    io = StringIO.new

    result = OpenAlexValidationReport.new(
      classifier: classifier,
      scope: Project.where(id: project.id)
    ).generate(io: io)

    row = CSV.parse(io.string, headers: true).sole
    assert_equal primary.openalex_id, row["label_topic_id"]
    assert_equal [additional.openalex_id, primary.openalex_id].sort.join("|"),
      row["work_topic_ids"]
    assert_equal "17|27", row["work_field_ids"]
    assert_equal "true", row["exact_topic_match"]
    assert_equal "true", row["exact_field_match"]
    assert_equal 1, result.dig(:overall, :exact_topic_matches)
  end

  test "exports a labelled row when repository text has no taxonomy match" do
    project = Project.create!(url: "https://github.com/test/unclassified-validation")
    topic = create_topic(openalex_id: "https://openalex.org/T30001")
    create_assignment(project, topic, source: "readme_doi")
    classifier = OpenAlexTopicClassifier.new(scope: OpenAlexTopic.none)
    io = StringIO.new

    result = OpenAlexValidationReport.new(
      classifier: classifier,
      scope: Project.where(id: project.id)
    ).generate(io: io)

    row = CSV.parse(io.string, headers: true).sole
    assert_nil row["predicted_topic_id"]
    assert_equal "false", row["exact_topic_match"]
    assert_equal 0, result.dig(:overall, :predicted_projects)
    assert_equal 0, result.dig(:by_source, "readme_doi", :predicted_labels)
  end

  test "groups label scores at stable boundaries" do
    report = OpenAlexValidationReport.new(scope: Project.none)

    assert_equal "<0.50", report.score_band(0.4999)
    assert_equal "0.50-0.79", report.score_band(0.5)
    assert_equal "0.80-0.94", report.score_band(0.8)
    assert_equal ">=0.95", report.score_band(0.95)
  end

  def create_topic(
    openalex_id:,
    name: "Software Engineering",
    keywords: ["Software Engineering"],
    subfield_id: "1712",
    subfield_name: "Software",
    field_id: "17",
    field_name: "Computer Science",
    domain_id: "3",
    domain_name: "Physical Sciences"
  )
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: name,
      description: "Research about #{name}",
      keywords: keywords,
      subfield_id: subfield_id,
      subfield_name: subfield_name,
      field_id: field_id,
      field_name: field_name,
      domain_id: domain_id,
      domain_name: domain_name
    )
  end

  def create_assignment(
    project,
    topic,
    source:,
    primary_topic: true,
    score: 0.95
  )
    ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: topic,
      score: score,
      primary_topic: primary_topic,
      source: source,
      source_identifier: "10.1000/validation",
      openalex_work_id: "https://openalex.org/W-validation"
    )
  end
end
