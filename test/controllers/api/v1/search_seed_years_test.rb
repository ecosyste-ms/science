require "test_helper"

class Api::V1::SearchSeedYearsTest < ActionDispatch::IntegrationTest
  test "retains release evidence and only suggests a bound for completed dated histories" do
    complete = project("complete")
    release(complete, "v1", "2012-05-01", tag_date: "2011-06-01")
    release(complete, "v2", "2020-01-01", tag_date: "2020-01-01")
    incomplete = project("incomplete")
    release(incomplete, "v2", "2020-01-01", tag_date: "2020-01-01")
    incomplete.update!(release_sync_state: incomplete.release_sync_state.deep_merge("tags" => { "page" => 2 }))
    undated = project("undated")
    release(undated, "v1", "2010-01-01", tag_date: "2010-01-01")
    release(undated, "v2", nil, tag_date: nil)
    stale = project("stale")
    release(stale, "v1", "2015-01-01", tag_date: "2015-01-01")
    stale.update!(repository: stale.repository.merge("tags_url" => "https://repos.example/changed/tags"))
    missing = Project.create!(url: "https://github.com/seed-years/missing", science_score: 50)
    conflicted = project("conflicted")
    release(conflicted, "v1", "2015-01-01", tag_date: "2015-01-01")
    conflicted.update!(release_sync_state: conflicted.release_sync_state.deep_merge("releases" => { "conflicts" => 1 }))
    tags_only = project("tags-only")
    tags_only.releases.create!(tag_name: "v1", tag_published_at: "2007-01-01", tag_fetched_at: Time.current)

    get "/api/v1/projects/search_seeds"

    assert_response :success
    records = response.parsed_body.index_by { |item| item.fetch("project_id") }
    assert_equal 2010, records.fetch(complete.id).dig("search_year", "suggested_start_year")
    assert_equal "2011-06-01T00:00:00Z", records.fetch(complete.id).dig("search_year", "earliest_release_at")
    evidence = records.fetch(complete.id).dig("search_year", "evidence")
    assert_equal %w[releases.tag_published_at releases.published_at], evidence.pluck("source")
    assert evidence.all? { |item| item["supports_bound"] }
    [incomplete, undated, stale, missing, conflicted].each do |item|
      assert_nil records.fetch(item.id).dig("search_year", "suggested_start_year"), item.url
    end
    assert_equal "2020-01-01T00:00:00Z", records.fetch(incomplete.id).dig("search_year", "earliest_release_at")
    assert_empty records.fetch(missing.id).dig("search_year", "evidence")
    assert_equal 2006, records.fetch(tags_only.id).dig("search_year", "suggested_start_year")
  end

  test "keeps package bounds separate and distinguishes explicit first dates from incomplete collected versions" do
    owner = project("packages")
    release(owner, "v1", "2010-01-01", tag_date: "2010-01-01")
    registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    explicit = package(owner, registry, "explicit", "first_release_published_at" => "2008-02-03T00:00:00Z")
    complete = package(owner, registry, "complete", "versions_url" => "https://packages.ecosyste.ms/api/v1/registries/pypi.org/packages/complete/versions")
    complete.update!(version_sync_state: PackageVersionSync.new(complete).source_identity.merge(
      "page" => 1, "completed_at" => Time.current.iso8601, "synced_through" => Time.current.iso8601))
    incomplete = package(owner, registry, "incomplete")
    undated = package(owner, registry, "undated", "versions_url" => "https://packages.ecosyste.ms/api/v1/registries/pypi.org/packages/undated/versions")
    undated.update!(version_sync_state: PackageVersionSync.new(undated).source_identity.merge(
      "page" => 1, "completed_at" => Time.current.iso8601, "synced_through" => Time.current.iso8601))
    [complete, incomplete, undated].each do |item|
      PackageVersion.import!(item, { "id" => item.id, "number" => "1.0", "published_at" => "2014-01-01T00:00:00Z" })
    end
    PackageVersion.import!(undated, { "id" => undated.id + 10000, "number" => "2.0" })
    owner.update!(packages: [{ "name" => "legacy", "first_release_published_at" => "2001-01-01T00:00:00Z" },
      { "name" => "invalid", "first_release_published_at" => "not a date" }])

    get "/api/v1/projects/search_seeds"

    assert_response :success
    record = response.parsed_body.sole
    assert_equal 2009, record.dig("search_year", "suggested_start_year")
    entries = record.fetch("packages").index_by { |item| item["package_id"] }
    assert_equal 2007, entries.fetch(explicit.id).dig("search_year", "suggested_start_year")
    assert_equal 2013, entries.fetch(complete.id).dig("search_year", "suggested_start_year")
    assert_nil entries.fetch(incomplete.id).dig("search_year", "suggested_start_year")
    assert_equal false, entries.fetch(incomplete.id).dig("search_year", "evidence").sole.fetch("supports_bound")
    assert_nil entries.fetch(undated.id).dig("search_year", "suggested_start_year")
    legacy = record.fetch("packages").find { |item| item["seeds"].any? { |seed| seed["value"] == "legacy" } }
    assert_equal 2000, legacy.dig("search_year", "suggested_start_year")
    assert_equal "project.packages[0].first_release_published_at", legacy.dig("search_year", "evidence").sole.fetch("source")
  end

  def project(name)
    repository = { "tags_url" => "https://repos.example/#{name}/tags", "releases_url" => "https://repos.example/#{name}/releases" }
    state = %w[tags releases].to_h { |source| [source, { "url" => repository.fetch("#{source}_url"), "page" => 1, "completed_at" => Time.current.iso8601 }] }
    Project.create!(url: "https://github.com/seed-years/#{name}", science_score: 50, repository: repository, release_sync_state: state)
  end

  def release(project, tag, date, tag_date:)
    project.releases.create!(tag_name: tag, uuid: tag, published_at: date, tag_published_at: tag_date, tag_fetched_at: Time.current)
  end

  def package(project, registry, name, metadata = {})
    Package.create!(published_by_project: project, package_registry: registry, name: name, purl: "pkg:pypi/#{name}", metadata: metadata)
  end
end
