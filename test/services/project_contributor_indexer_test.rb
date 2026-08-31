require "test_helper"

class ProjectContributorIndexerTest < ActiveSupport::TestCase
  test "indexes production-shaped contributors and links existing owners" do
    host = Host.create!(name: "GitHub")
    uuid_owner = Owner.create!(host: host, login: "renamed", uuid: "42")
    login_owner = Owner.create!(host: host, login: "octocat", uuid: "84")
    project = create_project(
      host: host,
      commits: {
        "committers" => [
          {
            "name" => "Ada Lovelace",
            "email" => "ADA@EXAMPLE.EDU",
            "login" => "AdaL",
            "uuid" => "42",
            "count" => 3,
          },
          {
            "name" => "Grace Hopper",
            "email" => "grace@example.edu",
            "login" => "OctoCat",
            "count" => 2,
          },
        ],
      }
    )

    result = ProjectContributorIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 2, result.fetch(:source_rows)
    assert_equal 2, result.fetch(:contributors)
    assert_equal 2, result.fetch(:owner_links)
    ada = project.project_contributors.find_by!(provider_uuid: "42")
    grace = project.project_contributors.find_by!(login: "octocat")
    assert_equal uuid_owner, ada.owner
    assert_equal "ada@example.edu", ada.email
    assert_equal 3, ada.contributions_count
    assert_equal "Ada Lovelace", ada.raw_data.fetch("name")
    assert_equal login_owner, grace.owner
    assert_equal "login:host-#{host.id}:octocat", grace.source_key
    assert_equal ProjectContributorIndexer::CURRENT_VERSION,
      project.reload.contributors_index_version
  end

  test "uses deterministic bot evidence and preserves human bot suffixes" do
    project = create_project(
      commits: {
        "committers" => [
          {
            "name" => "dependabot",
            "email" => "49699333+dependabot[bot]@users.noreply.github.com",
            "count" => 4,
          },
          {
            "name" => "Release Botany",
            "email" => "human@example.org",
            "login" => "release-bot",
            "count" => 2,
          },
          {
            "name" => "Service Account",
            "login" => "service-account",
            "type" => "Bot",
            "count" => 1,
          },
        ],
      }
    )

    result = ProjectContributorIndexer.new(project).sync!

    assert_equal 2, result.fetch(:bots)
    dependabot = project.project_contributors.find_by!(login: "dependabot[bot]")
    human = project.project_contributors.find_by!(login: "release-bot")
    source_bot = project.project_contributors.find_by!(login: "service-account")
    assert_equal "49699333", dependabot.provider_uuid
    assert_equal "noreply_bot_email", dependabot.classification_reason
    assert_equal "unknown", human.account_kind
    assert_nil human.classification_reason
    assert_equal "source_account_kind", source_bot.classification_reason
  end

  test "collapses duplicate source keys and combines contribution counts" do
    project = create_project(
      commits: {
        "committers" => [
          { "name" => "First", "login" => "Shared", "count" => 3 },
          { "name" => "Second", "login" => "shared", "count" => 7 },
        ],
      }
    )

    result = ProjectContributorIndexer.new(project).sync!

    assert_equal 2, result.fetch(:source_rows)
    assert_equal 1, result.fetch(:contributors)
    assert_equal 1, result.fetch(:duplicates)
    contributor = project.project_contributors.first
    assert_equal "shared", contributor.login
    assert_equal 10, contributor.contributions_count
  end

  test "uses a raw digest when identifiers are invalid" do
    project = create_project(
      commits: {
        "committers" => [
          {
            "name" => "Anonymous",
            "email" => "not-an-email",
            "login" => [],
            "uuid" => {},
            "count" => "invalid",
          },
        ],
      }
    )

    ProjectContributorIndexer.new(project).sync!

    contributor = project.project_contributors.first
    assert_match(/\Araw:[0-9a-f]{64}\z/, contributor.source_key)
    assert_nil contributor.email
    assert_nil contributor.login
    assert_nil contributor.provider_uuid
    assert_equal 0, contributor.contributions_count
    assert_equal "not-an-email", contributor.raw_data.fetch("email")
  end

  test "keeps fallback identities stable when contribution counts change" do
    project = create_project(
      commits: {
        "committers" => [{ "name" => "Anonymous", "count" => 1 }],
      }
    )
    ProjectContributorIndexer.new(project).sync!
    contributor_id = project.project_contributors.first.id
    project.update!(
      commits: {
        "committers" => [{ "name" => "Anonymous", "count" => 5 }],
      }
    )

    ProjectContributorIndexer.new(project).sync!

    contributor = project.project_contributors.first
    assert_equal contributor_id, contributor.id
    assert_equal 5, contributor.contributions_count
  end

  test "upserts changed contributors and removes stale rows" do
    project = create_project(
      commits: {
        "committers" => [
          { "email" => "first@example.org", "count" => 1 },
          { "email" => "second@example.org", "count" => 2 },
        ],
      }
    )
    ProjectContributorIndexer.new(project).sync!
    retained_id = project.project_contributors.find_by!(
      email: "second@example.org"
    ).id
    project.update!(
      commits: {
        "committers" => [
          { "email" => "second@example.org", "count" => 5 },
        ],
      }
    )

    result = ProjectContributorIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 1, project.project_contributors.count
    contributor = project.project_contributors.first
    assert_equal retained_id, contributor.id
    assert_equal 5, contributor.contributions_count
  end

  test "clears contributors after the source is removed" do
    project = create_project(
      commits: {
        "committers" => [{ "email" => "person@example.org", "count" => 1 }],
      }
    )
    ProjectContributorIndexer.new(project).sync!
    project.update!(commits: nil)

    result = ProjectContributorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:indexed)
    assert_empty project.project_contributors
    assert project.reload.contributors_indexed_at.present?
  end

  test "skips an unchanged indexed snapshot" do
    project = create_project(
      commits: {
        "committers" => [{ "email" => "person@example.org", "count" => 1 }],
      }
    )
    ProjectContributorIndexer.new(project).sync!
    contributor = project.project_contributors.first
    indexed_at = project.reload.contributors_indexed_at
    updated_at = contributor.updated_at

    travel 1.minute do
      result = ProjectContributorIndexer.new(project).sync!

      assert_not result.fetch(:indexed)
      assert_equal indexed_at, project.reload.contributors_indexed_at
      assert_equal updated_at, contributor.reload.updated_at
    end
  end

  test "records malformed source errors and retains the last snapshot" do
    project = create_project(
      commits: {
        "committers" => [{ "email" => "person@example.org", "count" => 1 }],
      }
    )
    ProjectContributorIndexer.new(project).sync!
    original = project.project_contributors.first.attributes
    project.update!(commits: { "committers" => "invalid" })

    result = ProjectContributorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:failed)
    assert_match "committers must be an array",
      project.reload.contributors_index_error
    assert_equal original, project.project_contributors.first.attributes
    assert_equal 0,
      ProjectContributorIndexer.sync_batch!(limit: 1).fetch(:selected)
  end

  test "retries errors from old parser versions" do
    project = create_project(
      commits: {
        "committers" => [{ "email" => "person@example.org", "count" => 1 }],
      }
    )
    ProjectContributorIndexer.new(project).sync!
    project.update!(commits: { "committers" => "invalid" })
    ProjectContributorIndexer.sync_batch!(limit: 1)
    project.update_columns(contributors_index_version: 0)

    result = ProjectContributorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:failed)
    assert_equal ProjectContributorIndexer::CURRENT_VERSION,
      project.reload.contributors_index_version
  end

  test "leaves a changed source pending" do
    original = {
      "committers" => [{ "email" => "first@example.org", "count" => 1 }],
    }
    changed = {
      "committers" => [{ "email" => "second@example.org", "count" => 1 }],
    }
    project = create_project(commits: original)
    indexer = ProjectContributorIndexer.new(project)
    indexer.define_singleton_method(:rows_for) do |content, source_digest|
      project.update_columns(commits: changed)
      super(content, source_digest)
    end

    result = indexer.sync!

    assert_not result.fetch(:indexed)
    assert_empty project.project_contributors
    assert_nil project.reload.contributors_indexed_at
  end

  test "processes a bounded batch of visible scientific projects" do
    first = create_project(commits: { "committers" => [] })
    second = create_project(commits: { "committers" => [] })
    create_project(
      science_score: 19,
      commits: { "committers" => [] }
    )

    result = ProjectContributorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:indexed)
    assert_equal 1,
      Project.where.not(contributors_indexed_at: nil)
        .where(id: [first.id, second.id]).count
  end

  test "indexes a twenty thousand contributor snapshot in chunks" do
    committers = 20_000.times.map do |index|
      {
        "name" => "Contributor #{index}",
        "email" => "contributor-#{index}@example.org",
        "count" => 1,
      }
    end
    project = create_project(commits: { "committers" => committers })

    result = ProjectContributorIndexer.new(project).sync!

    assert_equal 20_000, result.fetch(:contributors)
    assert_equal 20_000, project.project_contributors.count
  end

  test "rejects an invalid batch limit" do
    error = assert_raises(ArgumentError) do
      ProjectContributorIndexer.sync_batch!(limit: 0)
    end

    assert_equal "limit must be between 1 and 1000", error.message
  end

  def create_project(commits:, science_score: 20, host: nil)
    @project_number = @project_number.to_i + 1
    Project.create!(
      url: "https://github.com/test/contributor-index-#{@project_number}",
      science_score: science_score,
      host: host,
      commits: commits
    )
  end
end
