require "test_helper"

class ProjectRepositoryAliasIndexerTest < ActiveSupport::TestCase
  test "indexes normalized previous repository names" do
    project = Project.create!(
      url: "https://github.com/Science-Org/current-name",
      repository: {
        "previous_names" => [
          "Science-Org/Old-Name",
          "https://github.com/science-org/older-name.git",
        ],
      }
    )

    count = ProjectRepositoryAliasIndexer.new(project).sync!

    assert_equal 2, count
    assert_equal [
      "https://github.com/science-org/old-name",
      "https://github.com/science-org/older-name",
    ], project.repository_aliases.order(:url).pluck(:url)
    assert project.repository_aliases_indexed_at.present?
    assert_nil project.repository_aliases_index_error
  end

  test "marks a repository without previous names as indexed" do
    project = Project.create!(
      url: "https://github.com/science-org/current-name",
      repository: { "full_name" => "science-org/current-name" }
    )

    count = ProjectRepositoryAliasIndexer.new(project).sync!

    assert_equal 0, count
    assert project.repository_aliases_indexed_at.present?
    assert_empty project.repository_aliases
  end

  test "reindexes when stored repository data changes" do
    project = Project.create!(
      url: "https://github.com/science-org/current-name",
      repository: { "previous_names" => ["science-org/old-name"] }
    )
    ProjectRepositoryAliasIndexer.new(project).sync!

    project.update!(
      repository: { "previous_names" => ["science-org/older-name"] }
    )

    assert_nil project.repository_aliases_indexed_at
    ProjectRepositoryAliasIndexer.new(project).sync!
    assert_equal ["https://github.com/science-org/older-name"],
      project.repository_aliases.pluck(:url)
  end

  test "processes a bounded batch" do
    2.times do |index|
      Project.create!(
        url: "https://github.com/science-org/project-#{index}",
        repository: { "previous_names" => [] }
      )
    end

    result = ProjectRepositoryAliasIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:indexed)
    assert_equal 1,
      Project.where.not(repository_aliases_indexed_at: nil).count
  end
end
