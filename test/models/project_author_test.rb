require "test_helper"

class ProjectAuthorTest < ActiveSupport::TestCase
  test "belongs to a project snapshot position" do
    project = Project.create!(url: "https://github.com/test/project-author")
    author = ProjectAuthor.create!(
      project: project,
      source: "citation_cff",
      authorship_kind: "software",
      author_kind: "person",
      position: 1,
      source_path: "authors[0]",
      source_digest: "digest"
    )

    assert_equal project, author.project
    assert_raises(ActiveRecord::RecordInvalid) do
      ProjectAuthor.create!(author.attributes.except("id", "created_at", "updated_at"))
    end
  end

  test "is deleted with its project" do
    project = Project.create!(url: "https://github.com/test/project-author-delete")
    author = ProjectAuthor.create!(
      project: project,
      source: "citation_cff",
      authorship_kind: "software",
      author_kind: "person",
      position: 1,
      source_path: "authors[0]",
      source_digest: "digest"
    )

    project.destroy!

    assert_not ProjectAuthor.exists?(author.id)
  end
end
