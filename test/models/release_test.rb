require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  test "the database rejects a repeated project tag with another UUID or no UUID" do
    project = Project.create!(url: "https://github.com/science/unique-release-tags")
    release = project.releases.create!(tag_name: "v1", uuid: "123")

    ["456", nil].each do |uuid|
      assert_raises ActiveRecord::RecordNotUnique do
        Release.transaction(requires_new: true) do
          project.releases.create!(tag_name: "v1", uuid: uuid)
        end
      end
    end

    assert_equal release.id, project.releases.sole.id
  end

  test "tag uniqueness preserves case and prefixes and is scoped to the project" do
    project = Project.create!(url: "https://github.com/science/unique-release-tags")
    other = Project.create!(url: "https://gitlab.com/science/unique-release-tags")
    %w[v1 V1 1].each { |tag_name| project.releases.create!(tag_name: tag_name) }
    other.releases.create!(tag_name: "v1")

    assert_equal %w[1 V1 v1], project.releases.order(:tag_name).pluck(:tag_name)
    assert_equal "v1", other.releases.sole.tag_name
  end

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
