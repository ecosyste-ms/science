require "test_helper"
require "rake"

class TakedownRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("takedown:hide_user")
    ENV.delete("HOST")
    ENV.delete("LOGIN")
  end

  teardown do
    ENV.delete("HOST")
    ENV.delete("LOGIN")
  end

  test "hide_user hides and scrubs an owner and removes their projects" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(
      host: host,
      login: "Target-Owner",
      name: "Target Owner",
      email: "target@example.com",
      metadata: { "profile" => true }
    )
    project = Project.create!(
      host: host,
      owner_record: owner,
      url: "https://github.com/target-owner/project",
      science_score: 50
    )
    url_only_project = Project.create!(
      url: "https://github.com/target-owner/unlinked",
      science_score: 40
    )
    other_project = Project.create!(
      url: "https://github.com/other-owner/project",
      science_score: 30
    )
    issue = Issue.create!(project: project, title: "Issue")
    release = Release.create!(project: project, tag_name: "v1.0.0")
    field = Field.create!(name: "Biology", domain: "life_sciences")
    project_field = ProjectField.create!(project: project, field: field, confidence_score: 0.8)
    paper = Paper.create!(title: "Paper")
    mention = Mention.create!(project: project, paper: paper)
    vote = Vote.create!(project: project, score: 1)
    dependency = Dependency.create!(project: project, ecosystem: "rubygems", name: "example")
    contributor = Contributor.create!(
      login: "target-owner",
      email: "target@example.com",
      profile: { "name" => "Target Owner" }
    )
    other_contributor = Contributor.create!(
      login: "other-owner",
      email: "other@example.com"
    )
    ENV["LOGIN"] = "TARGET-OWNER"

    output, = capture_io { Rake::Task["takedown:hide_user"].execute }

    owner.reload
    assert owner.hidden?
    assert_nil owner.name
    assert_nil owner.email
    assert_equal({}, owner.metadata)
    assert_equal 0, owner.projects_count
    assert_not Project.exists?(project.id)
    assert_not Project.exists?(url_only_project.id)
    assert Project.exists?(other_project.id)
    assert_not Issue.exists?(issue.id)
    assert_not Release.exists?(release.id)
    assert_not ProjectField.exists?(project_field.id)
    assert_not Mention.exists?(mention.id)
    assert_not Vote.exists?(vote.id)
    assert_nil dependency.reload.project_id
    assert_not Contributor.exists?(contributor.id)
    assert Contributor.exists?(other_contributor.id)
    assert_equal 0, paper.reload.mentions_count
    assert_includes output, "[science] hidden owner GitHub/Target-Owner"
    assert_includes output, "[science] destroyed 2 projects"
    assert_includes output, "[science] destroyed 1 contributors"
  end

  test "hide_user creates a hidden tombstone for an unknown owner" do
    Host.create!(name: "GitHub", url: "https://github.com")
    ENV["LOGIN"] = "Missing-Owner"

    capture_io { Rake::Task["takedown:hide_user"].execute }

    owner = Owner.find_by(login: "missing-owner")
    assert owner.hidden?
  end

  test "hide_user aborts without LOGIN" do
    assert_raises(SystemExit) do
      capture_io { Rake::Task["takedown:hide_user"].execute }
    end
  end

  test "report describes a hidden owner and their projects" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(host: host, login: "Hidden-Owner")
    Project.create!(
      host: host,
      owner_record: owner,
      url: "https://github.com/hidden-owner/project"
    )
    owner.update!(hidden: true)
    ENV["LOGIN"] = "HIDDEN-OWNER"

    output, = capture_io { Rake::Task["takedown:report"].execute }

    assert_includes output, "[science] GitHub/HIDDEN-OWNER: owner=hidden projects=1 contributors=0"
  end
end
