require "test_helper"

class OpenAlexJossTopicImporterTest < ActiveSupport::TestCase
  test "replaces JOSS DOI assignments with current raw OpenAlex scores" do
    project = Project.create!(
      url: "https://github.com/test/joss-project",
      joss_metadata: { "doi" => "https://doi.org/10.21105/JOSS.00001" }
    )
    old_topic = create_topic("https://openalex.org/T-old")
    current_topic = create_topic("https://openalex.org/T1")
    ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: old_topic,
      score: 0.5,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00001",
      openalex_work_id: "https://openalex.org/W-old"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([
      {
        "id" => "https://openalex.org/W1",
        "doi" => "https://doi.org/10.21105/joss.00001",
        "primary_topic" => { "id" => current_topic.openalex_id, "score" => 0.94 },
        "topics" => [
          { "id" => current_topic.openalex_id, "score" => 0.94 },
          { "id" => "https://openalex.org/T-missing", "score" => 0.21 },
        ],
      },
    ])

    result = OpenAlexJossTopicImporter.sync!(client: client, scope: Project.where(id: project.id))

    assert_equal 1, result[:matched]
    assert_equal 0, result[:without_topics]
    assert_equal 1, result[:assignments]
    assert_equal 1, result[:unmatched_topics]
    assert_not ProjectOpenAlexTopic.exists?(open_alex_topic: old_topic)

    assignment = project.project_open_alex_topics.reload.sole
    assert_equal current_topic, assignment.open_alex_topic
    assert_equal 0.94, assignment.score
    assert assignment.primary_topic?
    assert_equal "10.21105/joss.00001", assignment.source_identifier
    assert_equal "https://openalex.org/W1", assignment.openalex_work_id
  end

  test "keeps prior assignments when OpenAlex has no matching work" do
    project = Project.create!(
      url: "https://github.com/test/missing-joss-work",
      joss_metadata: { "doi" => "10.21105/joss.00002" }
    )
    assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T2"),
      score: 0.7,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00002",
      openalex_work_id: "https://openalex.org/W2"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([])

    result = OpenAlexJossTopicImporter.sync!(client: client, scope: Project.where(id: project.id))

    assert_equal 1, result[:missing]
    assert ProjectOpenAlexTopic.exists?(assignment.id)
  end

  test "counts matched works without topics and clears their old assignments" do
    project = Project.create!(
      url: "https://github.com/test/joss-work-without-topics",
      joss_metadata: { "doi" => "10.21105/joss.00004" }
    )
    assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T4"),
      score: 0.7,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00004",
      openalex_work_id: "https://openalex.org/W-old"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([
      {
        "id" => "https://openalex.org/W4",
        "doi" => "https://doi.org/10.21105/joss.00004",
        "primary_topic" => nil,
        "topics" => [],
      },
    ])

    result = OpenAlexJossTopicImporter.sync!(client: client, scope: Project.where(id: project.id))

    assert_equal 1, result[:matched]
    assert_equal 1, result[:without_topics]
    assert_equal 0, result[:assignments]
    assert_not ProjectOpenAlexTopic.exists?(assignment.id)
  end

  test "assigns one OpenAlex work to every project sharing its JOSS DOI" do
    projects = 2.times.map do |index|
      Project.create!(
        url: "https://github.com/test/shared-joss-doi-#{index}",
        joss_metadata: { "doi" => "10.21105/joss.00003" }
      )
    end
    topic = create_topic("https://openalex.org/T3")
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([
      {
        "id" => "https://openalex.org/W3",
        "doi" => "https://doi.org/10.21105/joss.00003",
        "primary_topic" => { "id" => topic.openalex_id, "score" => 0.88 },
        "topics" => [{ "id" => topic.openalex_id, "score" => 0.88 }],
      },
    ])

    result = OpenAlexJossTopicImporter.sync!(
      client: client,
      scope: Project.where(id: projects.map(&:id))
    )

    assert_equal 2, result[:processed]
    assert_equal 2, result[:matched]
    assert_equal 2, result[:assignments]
    assert_equal projects.map(&:id).sort,
      ProjectOpenAlexTopic.where(open_alex_topic: topic).pluck(:project_id).sort
  end

  def create_topic(openalex_id)
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: "Research Software",
      subfield_id: "1712",
      subfield_name: "Software",
      field_id: "17",
      field_name: "Computer Science",
      domain_id: "3",
      domain_name: "Physical Sciences"
    )
  end
end
