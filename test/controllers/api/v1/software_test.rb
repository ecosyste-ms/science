require "test_helper"

class Api::V1::SoftwareTest < ActionDispatch::IntegrationTest
  setup { IndexSoftwareSearchWorker.jobs.clear }
  teardown { IndexSoftwareSearchWorker.jobs.clear }

  test "looks up names case insensitively and preserves ambiguous projects and provenance" do
    first = create_project(name: "Stats", packages: [{ "name" => "STATS", "purl" => "pkg:pypi/stats@1.0" }])
    second = create_project(name: "Stats", repository: { "fork" => true })
    create_project(name: "Stats", science_score: 19)
    hidden = create_project(name: "Stats")
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "hidden", hidden: true)
    hidden.update_columns(owner_id: owner.id)
    IndexSoftwareSearchWorker.drain

    get "/api/v1/software/lookup", params: { q: " STATS ", limit: 1 }
    assert_response :success
    body = response.parsed_body
    assert_equal "stats", body.fetch("query")
    assert_equal first.id, body.fetch("next_after_id")
    result = body.fetch("projects").sole
    assert_equal first.id, result.fetch("project_id")
    assert_equal "project.name", result.fetch("seeds").sole.fetch("source")
    assert_equal "project.packages[0].name", result.fetch("packages").sole.fetch("seeds").sole.fetch("source")
    assert_equal "pkg:pypi/stats", result.fetch("packages").sole.fetch("purl")
    assert result.fetch("indexed_at")

    get "/api/v1/software/lookup", params: { q: "stats", limit: 1, after_id: body.fetch("next_after_id") }
    assert_equal [second.id], response.parsed_body.fetch("projects").pluck("project_id")
    assert_nil response.parsed_body.fetch("next_after_id")
  end

  test "matches aliases citation identifiers and normalized package URLs" do
    project = create_project(
      name: "Café", repository: { "previous_names" => ["old/Climate"], "homepage" => "https://EXAMPLE.org/Docs" },
      citation_file: "cff-version: 1.2.0\nmessage: Cite this software\ntitle: Climate Lab\nauthors:\n  - name: Climate Team\ndoi: 10.1234/Climate\n",
      codemeta: { "alternateName" => ["ClimateTools"], "identifier" => "10.1234/Code" }.to_json,
      packages: [{ "name" => "Climate", "purl" => "pkg:pypi/climate@1.0" }]
    )
    IndexSoftwareSearchWorker.drain
    [
      [" CAFE\u0301 ", "name"], ["climatetools", "name"], ["Climate", "name"],
      ["https://doi.org/10.1234/CLIMATE", "doi"], ["10.1234/code", "doi"],
      ["https://GITHUB.COM:443/old/Climate", "repository_url"],
      ["https://example.org/Docs", "homepage_url"], ["pkg:pypi/climate@2.0", "purl"],
    ].each do |query, kind|
      get "/api/v1/software/lookup", params: { q: query, kind: kind }
      assert_response :success
      assert_equal [project.id], response.parsed_body.fetch("projects").pluck("project_id"), query
    end
    get "/api/v1/software/lookup", params: { q: "https://example.org/docs", kind: "homepage_url" }
    assert_empty response.parsed_body.fetch("projects")
  end

  test "searches names literally and paginates by project" do
    first = create_project(name: "SuperStats")
    second = create_project(name: "StatsTools")
    literal = create_project(name: "100%_Stats")
    IndexSoftwareSearchWorker.drain
    get "/api/v1/software/search", params: { q: "sTaTs", limit: 1 }
    assert_response :success
    assert_equal [first.id], response.parsed_body.fetch("projects").pluck("project_id")
    get "/api/v1/software/search", params: { q: "stats", after_id: first.id }
    assert_equal [second.id, literal.id], response.parsed_body.fetch("projects").pluck("project_id")
    get "/api/v1/software/search", params: { q: "0%_" }
    assert_equal [literal.id], response.parsed_body.fetch("projects").pluck("project_id")
    get "/api/v1/software/lookup", params: { q: "stats" }
    assert_empty response.parsed_body.fetch("projects")
    get "/api/v1/software/lookup", params: { q: "' OR 1=1 --" }
    assert_empty response.parsed_body.fetch("projects")
  end

  test "refreshes project and published package fields through committed writes" do
    project = create_project(name: "OldName")
    other = create_project(name: "Other")
    registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    package = Package.create!(name: "PackageName", purl: "pkg:pypi/packagename", package_registry: registry, published_by_project: project)
    IndexSoftwareSearchWorker.drain
    assert_lookup "PackageName", [project.id]
    project.update!(name: "NewName")
    package.update!(published_by_project: other, name: "MovedPackage")
    IndexSoftwareSearchWorker.drain
    assert_lookup "OldName", []
    assert_lookup "NewName", [project.id]
    assert_lookup "PackageName", []
    assert_lookup "MovedPackage", [other.id]
    package.destroy!
    IndexSoftwareSearchWorker.drain
    assert_lookup "MovedPackage", []
    project.update!(science_score: 0)
    IndexSoftwareSearchWorker.drain
    assert_empty project.reload.search_identifiers
  end

  test "refreshes stored repository aliases" do
    project = create_project(name: "Tools")
    record = project.repository_aliases.create!(url: "https://github.com/old/FormerName")
    IndexSoftwareSearchWorker.drain
    assert_lookup "FormerName", [project.id]
    record.destroy!
    IndexSoftwareSearchWorker.drain
    assert_lookup "FormerName", []
  end

  test "read requests never create projects or enqueue work" do
    assert_no_difference ["Project.count", "IndexSoftwareSearchWorker.jobs.size"] do
      assert_lookup "unknown", []
      get "/api/v1/software/search", params: { q: "unknown" }
      assert_response :success
    end
  end

  test "rejects invalid or unbounded parameters" do
    [
      {}, { q: " " }, { q: "x" * 2001 }, { q: "stats", kind: "sql" },
      { q: "stats", limit: 26 }, { q: "stats", limit: 0 }, { q: "stats", after_id: -1 },
      { q: "stats", after_id: "1.0" }, { q: "stats", limit: [] },
      { q: "javascript:alert(1)", kind: "homepage_url" },
      { q: "https://user:password@example.org", kind: "repository_url" },
      { q: "bad", kind: "purl" },
    ].each do |params|
      get "/api/v1/software/lookup", params: params
      assert_response :bad_request, params.inspect
    end
    get "/api/v1/software/search", params: { q: "st" }
    assert_response :bad_request
  end

  test "rechecks stale index candidates against current evidence" do
    project = create_project(name: "FormerName")
    IndexSoftwareSearchWorker.drain
    project.update!(name: "CurrentName")
    assert_lookup "FormerName", []
    IndexSoftwareSearchWorker.drain
    assert_lookup "CurrentName", [project.id]
  end

  def create_project(**attributes)
    Project.create!({ url: "https://github.com/search/#{SecureRandom.hex(6)}", science_score: 50 }.merge(attributes))
  end

  def assert_lookup(query, ids)
    get "/api/v1/software/lookup", params: { q: query }
    assert_response :success
    assert_equal ids, response.parsed_body.fetch("projects").pluck("project_id")
  end
end
