require "test_helper"

class ReleaseTagDeduplicatorTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(url: "https://github.com/science/tag-cleanup")
    @older = @project.releases.create!(tag_name: "nightly", uuid: "100",
      published_at: Time.utc(2026, 1, 1), body: "Old notes", immutable: false)
    @newer = @project.releases.create!(tag_name: "nightly", uuid: "200",
      published_at: Time.utc(2026, 2, 1), body: "New notes", immutable: true)
  end

  test "console preview makes no writes and apply retains the newest publication" do
    @older.update!(last_synced_at: Time.current, created_at: Time.current)
    original = @project.releases.order(:id).map(&:attributes)

    preview = ReleaseTagDeduplicator.run(limit: 10)

    assert_equal 1, preview[:selected]
    assert_equal 1, preview[:removable]
    assert_equal 0, preview[:removed]
    assert_equal @newer.id, preview[:examples].sole[:retained_id]
    assert_equal [@older.id], preview[:examples].sole[:removed_ids]
    assert_equal original, @project.releases.order(:id).map(&:attributes)

    applied = ReleaseTagDeduplicator.run(limit: 10, dry_run: false)

    assert_equal 1, applied[:removed]
    assert_equal @newer.id, @project.releases.sole.id
    assert_equal "New notes", @newer.reload.body
    assert_equal true, @newer.immutable
    assert_equal 0, ReleaseTagDeduplicator.run[:selected]
  end

  test "retains the highest local ID when publication dates are equal" do
    @older.update!(published_at: @newer.published_at)

    ReleaseTagDeduplicator.run(dry_run: false)

    assert_equal @newer.id, @project.releases.sole.id
  end

  test "preserves the most recently fetched tag observation separately from forge metadata" do
    @newer.update!(tag_sha: "a" * 40, tag_kind: "commit", tag_fetched_at: 2.days.ago)
    tag = @project.releases.create!(tag_name: "nightly", tag_sha: "b" * 40,
      tag_kind: "tag", tag_published_at: Time.utc(2026, 3, 1), tag_fetched_at: 1.day.ago,
      tag_url: "https://repos.ecosyste.ms/tag/nightly", purl: "pkg:github/science/tag-cleanup@nightly")

    result = ReleaseTagDeduplicator.run(dry_run: false)

    assert_equal 2, result[:removed]
    assert_equal tag.id, result[:examples].sole[:tag_metadata_id]
    assert_equal "b" * 40, @newer.reload.tag_sha
    assert_equal "tag", @newer.tag_kind
    assert_equal tag.purl, @newer.purl
    assert_equal tag.tag_fetched_at, @newer.tag_fetched_at
    assert_equal "200", @newer.uuid
    assert_equal "New notes", @newer.body
  end

  test "clears links to removed releases without changing links to the retained release" do
    registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    package = Package.create!(package_registry: registry, name: "tag-cleanup", published_by_project: @project)
    versions = [@older, @newer].each_with_index.map do |release, index|
      package.package_versions.create!(release: release, release_match_method: "packages_related_tag",
        number: index.to_s, ecosystems_id: index + 1, fetched_at: Time.current,
        related_tag: { "name" => "nightly" })
    end

    preview = ReleaseTagDeduplicator.run
    assert_equal 1, preview[:linked_versions]
    assert_equal @older.id, versions.first.reload.release_id

    result = ReleaseTagDeduplicator.run(dry_run: false)

    assert_equal 1, result[:linked_versions]
    assert_nil versions.first.reload.release_id
    assert_nil versions.first.release_match_method
    assert_equal({ "name" => "nightly" }, versions.first.related_tag)
    assert_equal @newer.id, versions.last.reload.release_id
    assert_equal "packages_related_tag", versions.last.release_match_method
  end

  test "does not rank undated forge releases or tag-only groups" do
    @older.update!(published_at: nil)
    2.times { @project.releases.create!(tag_name: "tag-only") }

    result = ReleaseTagDeduplicator.run(dry_run: false)

    assert_equal 2, result[:undated]
    assert_equal 0, result[:removed]
    assert_equal 4, @project.releases.count
  end

  test "bounds groups and resumes without combining projects or case-sensitive tags" do
    other = Project.create!(url: "https://gitlab.com/science/tag-cleanup")
    other.releases.create!(tag_name: "nightly", uuid: "100", published_at: @older.published_at)
    @project.releases.create!(tag_name: "Nightly", uuid: "300", published_at: @newer.published_at)
    2.times do |index|
      @project.releases.create!(tag_name: "v1", uuid: "v1-#{index}", published_at: @newer.published_at)
    end

    first = ReleaseTagDeduplicator.run(limit: 1, dry_run: false)
    assert_equal 1, first[:selected]
    assert_equal @older.id, first[:last_id]
    second = ReleaseTagDeduplicator.run(limit: 1, after_id: first[:last_id], dry_run: false)

    assert_equal 1, second[:removed]
    assert_equal %w[Nightly nightly v1], @project.releases.order(:tag_name).pluck(:tag_name)
    assert_equal 1, other.releases.count
    assert_equal 0, ReleaseTagDeduplicator.run(after_id: second[:last_id])[:selected]
  end

  test "leaves oversized groups untouched" do
    records = (1..ReleaseTagDeduplicator::MAX_GROUP_SIZE).map do |index|
      { project_id: @project.id, tag_name: "nightly", uuid: "extra-#{index}", published_at: Time.current }
    end
    Release.insert_all!(records)

    result = ReleaseTagDeduplicator.run(dry_run: false)

    assert_equal 1, result[:oversized]
    assert_equal 0, result[:removed]
    assert_equal records.length + 2, @project.releases.count
  end
end
