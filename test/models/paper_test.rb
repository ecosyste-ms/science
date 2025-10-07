require "test_helper"

class PaperTest < ActiveSupport::TestCase
  test "creates paper with valid attributes" do
    paper = Paper.create!(
      doi: "10.1234/example",
      openalex_id: "W12345678",
      title: "Example Research Paper",
      publication_date: Time.current,
      openalex_data: { type: "article" }
    )

    assert paper.persisted?
    assert_equal "10.1234/example", paper.doi
    assert_equal "W12345678", paper.openalex_id
    assert_equal "Example Research Paper", paper.title
    assert_equal 0, paper.mentions_count
  end

  test "has many mentions" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")

    mention = paper.mentions.create!(project: project)

    assert_equal 1, paper.mentions.count
    assert_equal mention, paper.mentions.first
  end

  test "has many projects through mentions" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project1 = Project.create!(url: "https://github.com/test/repo1")
    project2 = Project.create!(url: "https://github.com/test/repo2")

    paper.mentions.create!(project: project1)
    paper.mentions.create!(project: project2)

    assert_equal 2, paper.projects.count
    assert_includes paper.projects, project1
    assert_includes paper.projects, project2
  end

  test "destroys dependent mentions when destroyed" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper"
    )
    project = Project.create!(url: "https://github.com/test/repo")
    paper.mentions.create!(project: project)

    assert_difference "Mention.count", -1 do
      paper.destroy
    end
  end

  test "stores urls as array" do
    paper = Paper.create!(
      doi: "10.1234/example",
      title: "Example Paper",
      urls: ["https://example.com/paper1", "https://example.com/paper2"]
    )

    assert_equal 2, paper.urls.length
    assert_includes paper.urls, "https://example.com/paper1"
  end
end
