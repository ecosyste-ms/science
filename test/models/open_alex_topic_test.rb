require "test_helper"

class OpenAlexTopicTest < ActiveSupport::TestCase
  test "connects projects through scored assignments" do
    project = Project.create!(url: "https://github.com/test/open-alex")
    topic = create_topic
    assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: topic,
      score: 0.91,
      primary_topic: true,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00001",
      openalex_work_id: "https://openalex.org/W1"
    )

    assert_equal [topic], project.open_alex_topics
    assert_equal [project], topic.projects
    assert_equal [assignment], project.project_open_alex_topics.primary
  end

  test "requires an assignment score between zero and one" do
    assignment = ProjectOpenAlexTopic.new(
      project: Project.create!(url: "https://github.com/test/invalid-score"),
      open_alex_topic: create_topic,
      score: 1.1,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00002",
      openalex_work_id: "https://openalex.org/W2"
    )

    assert_not assignment.valid?
    assert_includes assignment.errors[:score], "must be less than or equal to 1"
  end

  def create_topic
    OpenAlexTopic.create!(
      openalex_id: "https://openalex.org/T1",
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
