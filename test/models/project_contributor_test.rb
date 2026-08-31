require "test_helper"

class ProjectContributorTest < ActiveSupport::TestCase
  test "belongs to a project source key" do
    project = Project.create!(url: "https://github.com/test/project-contributor")
    contributor = ProjectContributor.create!(
      project: project,
      source: "commits_ecosyste_ms",
      source_key: "email:person@example.edu",
      account_kind: "unknown",
      contributions_count: 3,
      source_digest: "digest"
    )

    assert_equal project, contributor.project
    assert_raises(ActiveRecord::RecordInvalid) do
      ProjectContributor.create!(
        contributor.attributes.except("id", "created_at", "updated_at")
      )
    end
  end

  test "is deleted with its project and retains a deleted owner observation" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "contributor-owner")
    project = Project.create!(url: "https://github.com/test/contributor-delete")
    contributor = ProjectContributor.create!(
      project: project,
      owner: owner,
      source: "commits_ecosyste_ms",
      source_key: "login:github:contributor-owner",
      account_kind: "unknown",
      source_digest: "digest"
    )

    owner.destroy!
    assert_nil contributor.reload.owner_id

    project.destroy!
    assert_not ProjectContributor.exists?(contributor.id)
  end
end
