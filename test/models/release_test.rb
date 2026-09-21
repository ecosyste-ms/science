require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  test "the database rejects a repeated project UUID even with a different tag" do
    project = Project.create!(url: "https://github.com/science/unique-releases")
    project.releases.create!(uuid: "123", tag_name: "v1")

    assert_raises ActiveRecord::RecordNotUnique do
      Release.transaction(requires_new: true) do
        project.releases.create!(uuid: "123", tag_name: "v2")
      end
    end

    assert_equal ["v1"], project.releases.pluck(:tag_name)
  end

  test "UUID uniqueness is scoped to each project and excludes missing UUIDs" do
    project = Project.create!(url: "https://github.com/science/unique-releases")
    other = Project.create!(url: "https://gitlab.com/science/unique-releases")
    project.releases.create!(uuid: "123", tag_name: "v1")
    other.releases.create!(uuid: "123", tag_name: "v1")
    [nil, nil, "", ""].each_with_index do |uuid, index|
      project.releases.create!(uuid: uuid, tag_name: "tag-#{index}")
    end

    assert_equal 5, project.releases.count
    assert_equal 1, other.releases.count
  end
end
