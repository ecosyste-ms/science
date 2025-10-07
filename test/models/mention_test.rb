require "test_helper"

class MentionTest < ActiveSupport::TestCase
  test "creates mention with valid attributes" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")

    mention = Mention.create!(
      paper: paper,
      project: project
    )

    assert mention.persisted?
    assert_equal paper, mention.paper
    assert_equal project, mention.project
  end

  test "belongs to paper" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")
    mention = Mention.create!(paper: paper, project: project)

    assert_equal paper, mention.paper
  end

  test "belongs to project" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")
    mention = Mention.create!(paper: paper, project: project)

    assert_equal project, mention.project
  end

  test "increments project mentions_count on create" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")

    assert_equal 0, project.mentions_count

    Mention.create!(paper: paper, project: project)
    project.reload

    assert_equal 1, project.mentions_count
  end

  test "decrements project mentions_count on destroy" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")
    mention = Mention.create!(paper: paper, project: project)
    project.reload

    assert_equal 1, project.mentions_count

    mention.destroy
    project.reload

    assert_equal 0, project.mentions_count
  end
end
