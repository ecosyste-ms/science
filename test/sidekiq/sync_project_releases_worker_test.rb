require "test_helper"

class SyncProjectReleasesWorkerTest < ActiveSupport::TestCase
  setup do
    SyncProjectReleasesWorker.jobs.clear
    @project = Project.create!(url: "https://gitlab.com/science/tool", repository: {
      "tags_url" => "https://repos.ecosyste.ms/test/tags",
      "releases_url" => "https://repos.ecosyste.ms/test/releases"
    })
  end

  teardown { SyncProjectReleasesWorker.jobs.clear }

  test "project sync schedules independent sources without fetching metadata" do
    @project.sync_releases

    assert_equal [[@project.id, "tags"], [@project.id, "releases"]], SyncProjectReleasesWorker.jobs.map { |job| job["args"] }
    assert_not_requested :get, /repos.ecosyste.ms/
  end

  test "a tag-only forge imports without a release endpoint" do
    @project.update!(repository: @project.repository.except("releases_url"))
    respond_with("tags", [tag])

    @project.sync_releases
    SyncProjectReleasesWorker.drain

    release = @project.releases.sole
    assert_equal "v1.0", release.tag_name
    assert_equal "a" * 40, release.tag_sha
    assert_equal "commit", release.tag_kind
    assert_nil release.uuid
    assert_nil release.published_at
    assert_equal Time.utc(2025, 1, 1), release.tag_published_at
    assert @project.reload.release_sync_state.dig("tags", "completed_at").present?
  end

  test "either import order enriches the same record without losing source fields" do
    [%w[tags releases], %w[releases tags]].each do |sources|
      @project.releases.delete_all
      @project.reload.update!(release_sync_state: {})
      respond_with("tags", [tag])
      respond_with("releases", [forge_release])

      perform(sources.first)
      id = @project.releases.sole.id
      perform(sources.last)

      release = @project.releases.sole
      assert_equal id, release.id
      assert_equal "Release notes", release.body
      assert_equal "a" * 40, release.tag_sha
      assert_equal Time.utc(2025, 1, 1), release.tag_published_at
      assert_equal Time.utc(2025, 1, 2), release.published_at
      assert_equal true, release.immutable
      assert_equal Time.utc(2024, 12, 31), release.forge_created_at
      assert release.tag_fetched_at.present?
      assert release.release_fetched_at.present?
    end
  end

  test "case and v prefixes remain distinct tag identities" do
    respond_with("tags", %w[v1.0 V1.0 1.0].map { |name| tag.merge("name" => name) })

    perform("tags")

    assert_equal %w[1.0 V1.0 v1.0], @project.releases.order(:tag_name).pluck(:tag_name)
  end

  test "imports one page per job and resumes using the next link" do
    respond_with("tags", [tag], headers: { "Link" => '<https://repos.ecosyste.ms/test/tags?page=2>; rel="next"' })
    respond_with("tags", [tag.merge("name" => "v2")], page: 2)

    perform("tags")

    assert_equal 1, @project.releases.count
    assert_equal 2, @project.reload.release_sync_state.dig("tags", "page")
    assert_nil @project.release_sync_state.dig("tags", "completed_at")
    assert_equal [[@project.id, "tags"]], SyncProjectReleasesWorker.jobs.map { |job| job["args"] }
    SyncProjectReleasesWorker.drain
    assert_equal 2, @project.releases.count
    assert_equal 1, @project.reload.release_sync_state.dig("tags", "page")
    assert @project.release_sync_state.dig("tags", "completed_at").present?
  end

  test "a failed page keeps progress and honors retry-after without blocking the other source" do
    @project.update!(release_sync_state: { "tags" => { "url" => @project.repository["tags_url"], "page" => 2 } })
    respond_with("tags", [], page: 2, status: 429, headers: { "Retry-After" => "7200" })
    respond_with("releases", [forge_release])

    travel_to Time.utc(2026, 9, 20, 12) do
      perform("tags")
      perform("releases")

      state = @project.reload.release_sync_state.fetch("tags")
      assert_equal 2, state["page"]
      assert_includes state["error"], "429"
      assert_equal 2.hours.from_now, Time.iso8601(state["retry_at"])
      assert_equal 2.hours.from_now.to_f, SyncProjectReleasesWorker.jobs.sole["at"]
      assert_equal "release-1", @project.releases.sole.uuid

      respond_with("tags", [tag], page: 2)
      travel 2.hours
      perform("tags")
      assert_nil @project.reload.release_sync_state.dig("tags", "error")
      assert_equal "a" * 40, @project.releases.sole.tag_sha
    end
  end

  test "a malformed record rolls back the page without advancing the cursor" do
    respond_with("tags", [tag, { "sha" => "b" * 40 }])

    perform("tags")

    assert_empty @project.releases
    state = @project.reload.release_sync_state.fetch("tags")
    assert_equal 1, state["page"]
    assert_includes state["error"], "tag name"
    assert_nil state["completed_at"]
  end

  test "rejects a non-list response and retains existing releases" do
    existing = @project.releases.create!(tag_name: "v0", uuid: "old")
    respond_with("tags", { "message" => "repository response" })

    perform("tags")

    assert_equal [existing.id], @project.releases.pluck(:id)
    assert_includes @project.reload.release_sync_state.dig("tags", "error"), "expected a list"
  end

  test "rechecks update moved tags and keep forge metadata intact" do
    respond_with("tags", [tag])
    respond_with("releases", [forge_release])
    perform("tags")
    perform("releases")
    release = @project.releases.sole
    respond_with("tags", [tag.merge("sha" => "b" * 40, "body" => "ignored", "immutable" => false)])

    travel 2.days do
      perform("tags")
    end

    assert_equal "b" * 40, release.reload.tag_sha
    assert_equal "Release notes", release.body
    assert_equal true, release.immutable
  end

  test "unchanged records are not rewritten on reconciliation" do
    respond_with("tags", [tag])
    perform("tags")
    release = @project.releases.sole
    updated_at = release.updated_at
    fetched_at = release.tag_fetched_at

    travel 2.days do
      perform("tags")
    end

    assert_equal updated_at, release.reload.updated_at
    assert_equal fetched_at, release.tag_fetched_at
    assert_equal 1, @project.releases.count
  end

  test "an upstream sync timestamp alone does not rewrite a release" do
    respond_with("releases", [forge_release.merge("last_synced_at" => "2025-01-03T00:00:00Z")])
    perform("releases")
    release = @project.releases.sole
    updated_at = release.updated_at
    respond_with("releases", [forge_release.merge("last_synced_at" => "2025-01-04T00:00:00Z")])

    travel 2.days do
      perform("releases")
    end

    assert_equal updated_at, release.reload.updated_at
  end

  test "conflicting forge identities leave stored metadata unchanged" do
    existing = @project.releases.create!(tag_name: "v1.0", uuid: "different-release", body: "Keep")
    respond_with("releases", [forge_release])

    perform("releases")

    assert_equal "Keep", existing.reload.body
    assert_equal 1, @project.reload.release_sync_state.dig("releases", "conflicts")
    assert_includes @project.release_sync_state.dig("releases", "conflict_examples").first, "conflicting release UUID"
  end

  test "duplicate existing identities are reported without deleting records" do
    2.times { @project.releases.create!(tag_name: "v1.0", uuid: "release-1") }
    respond_with("tags", [tag, tag.merge("name" => "v2")])

    perform("tags")

    assert_equal 3, @project.releases.count
    assert_equal 1, @project.reload.release_sync_state.dig("tags", "conflicts")
    assert_includes @project.release_sync_state.dig("tags", "conflict_examples").first, "duplicate tag"
    assert @project.release_sync_state.dig("tags", "completed_at").present?
  end

  test "an active claim prevents an overlapping import and expired claims resume" do
    @project.update!(release_sync_state: { "tags" => {
      "url" => @project.repository["tags_url"], "page" => 1,
      "token" => "another-worker", "started_at" => Time.current.iso8601
    } })
    perform("tags")
    assert_not_requested :get, /repos.ecosyste.ms/
    respond_with("tags", [tag])

    travel 6.minutes do
      perform("tags")
    end

    assert_equal 1, @project.releases.count
  end

  test "hidden projects are not imported" do
    host = Host.create!(name: "GitLab")
    owner = Owner.create!(host: host, login: "science", hidden: true)
    @project.update_columns(owner_id: owner.id)

    perform("tags")

    assert_not_requested :get, /repos.ecosyste.ms/
    assert_empty @project.releases
  end

  def tag
    {
      "name" => "v1.0", "sha" => "a" * 40, "kind" => "commit",
      "published_at" => "2025-01-01T00:00:00Z",
      "html_url" => "https://gitlab.com/science/tool/-/tags/v1.0"
    }
  end

  def forge_release
    {
      "uuid" => "release-1", "tag_name" => "v1.0", "name" => "First release",
      "body" => "Release notes", "immutable" => true,
      "published_at" => "2025-01-02T00:00:00Z", "created_at" => "2024-12-31T00:00:00Z"
    }
  end

  def respond_with(source, records, page: 1, status: 200, headers: {})
    stub_request(:get, @project.repository.fetch("#{source}_url"))
      .with(query: { per_page: "100", page: page.to_s, sort: "id", order: "asc" })
      .to_return(status: status, body: records.to_json, headers: headers)
  end

  def perform(source)
    SyncProjectReleasesWorker.new.perform(@project.id, source)
  end
end
