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

  test "returns several distinct fields ranked by their best matching topic" do
    genomics = create_topic(
      openalex_id: "https://openalex.org/T-field-1",
      name: "Genome Sequence Analysis",
      keywords: ["Genomics", "DNA Sequencing"]
    )
    related_genomics = create_topic(
      openalex_id: "https://openalex.org/T-field-2",
      name: "Genome Assembly",
      keywords: ["Genome Assembly"]
    )
    climate = create_topic(
      openalex_id: "https://openalex.org/T-field-3",
      name: "Climate Modelling",
      keywords: ["Climate Models"],
      field_id: "23",
      field_name: "Environmental Science"
    )
    project = Project.new(
      url: "https://github.com/test/genome-climate",
      name: "Genome Sequence Toolkit",
      description: "Genome assembly with climate model inputs",
      keywords: %w[genomics sequencing climate]
    )

    fields = OpenAlexTopicClassifier.new.classify_project_fields(project)

    assert_equal %w[17 23], fields.map(&:field_id)
    assert_equal "Biochemistry, Genetics and Molecular Biology", fields.first.field_name
    assert_includes fields.first.topic_ids, genomics.openalex_id
    assert_includes fields.first.topic_ids, related_genomics.openalex_id
    assert_equal [climate.openalex_id], fields.second.topic_ids
    assert_operator fields.first.score, :>, fields.second.score
  end

  test "collapses the top five topics without filling from lower-ranked topics" do
    topics = []
    topics << create_topic(openalex_id: "https://openalex.org/T10", name: "Genome Analysis")
    topics << create_topic(openalex_id: "https://openalex.org/T20", name: "Genome Analysis")
    topics << create_topic(
      openalex_id: "https://openalex.org/T30",
      name: "Genome Analysis",
      field_id: "23",
      field_name: "Environmental Science"
    )
    topics << create_topic(
      openalex_id: "https://openalex.org/T40",
      name: "Genome Analysis",
      field_id: "24",
      field_name: "Immunology and Microbiology"
    )
    topics << create_topic(
      openalex_id: "https://openalex.org/T50",
      name: "Genome Analysis",
      field_id: "25",
      field_name: "Materials Science"
    )
    topics << create_topic(
      openalex_id: "https://openalex.org/T60",
      name: "Genome Analysis",
      field_id: "26",
      field_name: "Mathematics"
    )
    predictions = topics.each_with_index.map do |topic, index|
      OpenAlexTopicClassifier::Prediction.new(
        topic: topic,
        score: 1.0 - (index * 0.1),
        matched_terms: ["genome"]
      )
    end
    classifier = OpenAlexTopicClassifier.new(scope: OpenAlexTopic.none)
    classifier.define_singleton_method(:classify_project) do |_project, limit:|
      predictions.first(limit)
    end

    fields = classifier.classify_project_fields(Project.new)

    assert_equal %w[17 23 24 25], fields.map(&:field_id)
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
