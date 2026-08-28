require "test_helper"

class OpenAlexTopicClassifierTest < ActiveSupport::TestCase
  test "ranks OpenAlex topics from realistic repository text" do
    genomics = create_topic(
      openalex_id: "https://openalex.org/T1",
      name: "Genomics and Sequence Analysis",
      keywords: ["Genomics", "DNA Sequencing"]
    )
    create_topic(
      openalex_id: "https://openalex.org/T2",
      name: "Fluid Mechanics",
      keywords: ["Turbulence", "Fluid Flow"],
      field_id: "22",
      field_name: "Engineering"
    )
    project = Project.new(
      url: "https://github.com/test/genome-toolkit",
      name: "Genome Toolkit",
      description: "Analysis of genomics and DNA sequencing data",
      readme: "# Genome Toolkit\n\nProcess genomic sequences and DNA variants.",
      keywords: %w[genomics dna-sequencing]
    )

    prediction = OpenAlexTopicClassifier.new.classify_project(project).first

    assert_equal genomics, prediction.topic
    assert_operator prediction.score, :>, 0.0
    assert_operator prediction.score, :<=, 1.0
    assert_includes prediction.matched_terms, "genomics"
    assert_empty project.project_open_alex_topics
  end

  test "returns no prediction without a taxonomy term match" do
    create_topic(
      openalex_id: "https://openalex.org/T3",
      name: "Quantum Chromodynamics",
      keywords: ["Particle Physics"]
    )
    project = Project.new(url: "https://github.com/test/billing-dashboard")

    predictions = OpenAlexTopicClassifier.new.classify_project(project)

    assert_empty predictions
  end

  test "ignores repository boilerplate" do
    create_topic(
      openalex_id: "https://openalex.org/T4",
      name: "Open Source Software Innovations",
      keywords: ["Open Source Software"]
    )
    project = Project.new(
      url: "https://github.com/test/example",
      description: "An open source software package for Python"
    )

    predictions = OpenAlexTopicClassifier.new.classify_project(project)

    assert_empty predictions
  end

  test "limits predictions and orders tied scores by stable OpenAlex ID" do
    second = create_topic(openalex_id: "https://openalex.org/T20", name: "Genome Analysis")
    first = create_topic(openalex_id: "https://openalex.org/T10", name: "Genome Analysis")
    project = Project.new(url: "https://github.com/test/genome", name: "Genome Analysis")

    predictions = OpenAlexTopicClassifier.new.classify_project(project, limit: 1)

    assert_equal 1, predictions.length
    assert_equal first, predictions.first.topic
    refute_equal second, predictions.first.topic
  end

  def create_topic(
    openalex_id:,
    name:,
    keywords: [],
    field_id: "17",
    field_name: "Biochemistry, Genetics and Molecular Biology"
  )
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: name,
      description: "Research about #{name}",
      keywords: keywords,
      subfield_id: "1306",
      subfield_name: "Genetics",
      field_id: field_id,
      field_name: field_name,
      domain_id: "1",
      domain_name: "Life Sciences"
    )
  end
end
