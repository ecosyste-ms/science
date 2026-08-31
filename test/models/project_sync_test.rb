require "test_helper"

class ProjectSyncTest < ActiveSupport::TestCase
  def repo_hash
    {
      "full_name" => "numpy/numpy",
      "owner" => "numpy",
      "host" => { "name" => "GitHub", "url" => "https://github.com", "kind" => "github" },
      "html_url" => "https://github.com/numpy/numpy",
      "default_branch" => "main",
      "download_url" => "https://github.com/numpy/numpy/archive/main.tar.gz",
      "releases_url" => "https://repos.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/releases",
      "manifests_url" => "https://repos.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/manifests",
      "metadata" => {
        "files" => {
          "readme" => "README.md",
          "codemeta" => "codemeta.json",
          "citation" => "CITATION.cff",
          "zenodo" => ".zenodo.json",
        },
      },
    }
  end

  def build_project(overrides = {})
    Project.create!({ url: "https://github.com/numpy/numpy", repository: repo_hash }.merge(overrides))
  end

  # ---- URL builders ----

  test "api urls" do
    p = build_project
    assert_equal "https://repos.ecosyste.ms/api/v1/repositories/lookup?url=https://github.com/numpy/numpy", p.repos_api_url
    assert_equal "https://packages.ecosyste.ms/api/v1/packages/lookup?repository_url=https://github.com/numpy/numpy", p.packages_url
    assert_equal "https://commits.ecosyste.ms/api/v1/repositories/lookup?url=https://github.com/numpy/numpy", p.commits_api_url
    assert_equal "https://issues.ecosyste.ms/api/v1/repositories/lookup?url=https://github.com/numpy/numpy", p.issues_api_url
    assert_equal "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/numpy", p.owner_api_url
    assert_equal "https://timeline.ecosyste.ms/api/v1/events/numpy/numpy/summary", p.timeline_url
  end

  test "ping urls" do
    p = build_project(packages: [{ "name" => "numpy", "registry" => { "name" => "pypi.org" } }])
    assert_equal "https://repos.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/ping", p.repos_ping_url
    assert_equal "https://issues.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/ping", p.issues_ping_url
    assert_equal "https://commits.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/ping", p.commits_ping_url
    assert_equal ["https://packages.ecosyste.ms/api/v1/registries/pypi.org/packages/numpy/ping"], p.packages_ping_urls
    assert_equal "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owner/numpy/ping", p.owner_ping_url
    assert_equal 5, p.ping_urls.length
  end

  test "ping urls return nil or empty when no repository" do
    p = Project.new(url: "https://github.com/x/y")
    assert_nil p.repos_ping_url
    assert_nil p.issues_ping_url
    assert_nil p.commits_ping_url
    assert_nil p.owner_ping_url
    assert_nil p.owner_api_url
    assert_nil p.timeline_url
    assert_equal [], p.packages_ping_urls
    assert_equal [], p.ping_urls
  end

  test "file urls" do
    p = build_project
    assert_equal "https://github.com/numpy/numpy/archive/main.tar.gz", p.download_url
    assert_equal "https://github.com/numpy/numpy/blob/main/README.md", p.readme_url
    assert_equal "https://github.com/numpy/numpy/blob/main/foo", p.blob_url("foo")
    assert_equal "https://github.com/numpy/numpy/raw/main/foo", p.raw_url("foo")
    assert_equal "https://archives.ecosyste.ms/api/v1/archives/contents?url=https://github.com/numpy/numpy/archive/main.tar.gz&path=README.md", p.archive_url("README.md")
  end

  test "timeline_url is nil for non-github hosts" do
    p = build_project(repository: repo_hash.merge("host" => { "name" => "GitLab" }))
    assert_nil p.timeline_url
  end

  # ---- fetchers ----

  test "fetch_repository stores parsed body" do
    p = Project.create!(url: "https://github.com/numpy/numpy")
    stub_request(:get, p.repos_api_url).to_return(status: 200, body: { full_name: "numpy/numpy" }.to_json)
    p.fetch_repository
    assert_equal "numpy/numpy", p.reload.repository["full_name"]
  end

  test "fetch_owner stores parsed body" do
    p = build_project
    stub_request(:get, p.owner_api_url).to_return(status: 200, body: { login: "numpy" }.to_json)
    p.fetch_owner
    assert_equal "numpy", p.reload.owner["login"]
  end

  test "fetch_owner returns early without owner_api_url" do
    p = Project.create!(url: "https://github.com/x/y")
    assert_nil p.fetch_owner
  end

  test "fetch_packages stores records and links existing unlinked packages" do
    p = build_project
    registry = PackageRegistry.create!(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "numpy",
      purl: "pkg:pypi/numpy"
    )
    record = package_record(
      name: "numpy",
      purl: "pkg:pypi/numpy@2.3.0",
      registry: registry
    )
    stub_request(:get, p.packages_url).to_return(
      status: 200,
      body: [record].to_json
    )

    p.fetch_packages

    assert_equal "numpy", p.reload.packages.first["name"]
    assert_equal p, package.reload.published_by_project
  end

  test "fetch_packages does not create missing packages or change existing links" do
    p = build_project
    other_project = Project.create!(url: "https://github.com/scipy/scipy")
    checked_at = 2.days.ago
    registry = PackageRegistry.create!(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "numpy",
      purl: "pkg:pypi/numpy",
      published_by_project: other_project,
      repository_checked_at: checked_at
    )
    records = [
      package_record(
        name: "numpy",
        purl: "pkg:pypi/numpy",
        registry: registry
      ),
      package_record(
        name: "missing",
        purl: "pkg:pypi/missing",
        registry: registry
      ),
    ]
    stub_request(:get, p.packages_url).to_return(
      status: 200,
      body: records.to_json
    )

    p.fetch_packages

    assert_equal 1, Package.count
    assert_equal other_project, package.reload.published_by_project
    assert_equal checked_at, package.repository_checked_at
  end

  test "fetch_commits stores parsed body" do
    p = build_project
    stub_request(:get, p.commits_api_url).to_return(status: 200, body: { total_commits: 5 }.to_json)
    p.fetch_commits
    assert_equal 5, p.reload.commits["total_commits"]
  end

  def package_record(name:, purl:, registry:)
    {
      "id" => 123,
      "name" => name,
      "namespace" => nil,
      "purl" => purl,
      "repository_url" => "https://github.com/numpy/numpy",
      "updated_at" => "2026-08-31T12:00:00Z",
      "dependent_repos_count" => 200,
      "rankings" => {
        "dependent_repos_count" => 0.4,
        "average" => 1.5,
      },
      "registry" => {
        "name" => registry.name,
        "url" => registry.url,
        "ecosystem" => registry.ecosystem,
      },
    }
  end

  test "fetch_commits returns early without repository" do
    p = Project.create!(url: "https://github.com/x/y")
    assert_nil p.fetch_commits
  end

  test "fetch_issue_stats stores parsed body" do
    p = build_project
    stub_request(:get, p.issues_api_url).to_return(status: 200, body: { open_issues: 3 }.to_json)
    p.fetch_issue_stats
    assert_equal 3, p.reload.issues_stats["open_issues"]
  end

  test "fetch_events stores summary and last_year" do
    p = build_project
    stub_request(:get, p.timeline_url).to_return(status: 200, body: { pushes: 1 }.to_json)
    stub_request(:get, /#{Regexp.escape(p.timeline_url)}\?after=/).to_return(status: 200, body: { pushes: 2 }.to_json)
    p.fetch_events
    assert_equal 1, p.reload.events["total"]["pushes"]
    assert_equal 2, p.events["last_year"]["pushes"]
  end

  test "fetch_dependencies stores parsed body and clears stale indexing state" do
    p = build_project(
      dependencies: [{ "ecosystem" => "rubygems" }],
      dependencies_indexed_at: 1.day.ago,
      dependencies_index_error: "old error"
    )
    stub_request(:get, repo_hash["manifests_url"])
      .to_return(status: 200, body: [{ ecosystem: "pypi" }].to_json)

    p.fetch_dependencies

    assert_equal "pypi", p.reload.dependencies.first["ecosystem"]
    assert_nil p.dependencies_indexed_at
    assert_nil p.dependencies_index_error
  end

  test "fetch_dependencies retains indexing state for unchanged manifests" do
    manifests = [{ "ecosystem" => "pypi" }]
    indexed_at = 1.day.ago
    p = build_project(
      dependencies: manifests,
      dependencies_indexed_at: indexed_at,
      dependencies_index_error: "retry manually"
    )
    stub_request(:get, repo_hash["manifests_url"])
      .to_return(status: 200, body: manifests.to_json)

    p.fetch_dependencies

    assert_in_delta indexed_at, p.reload.dependencies_indexed_at, 1.second
    assert_equal "retry manually", p.dependencies_index_error
  end

  test "fetch_citation_file stores contents from archives api" do
    p = build_project
    stub_request(:get, p.archive_url("CITATION.cff")).to_return(status: 200, body: { contents: "cff-version: 1.2.0" }.to_json)
    p.fetch_citation_file
    assert_equal "cff-version: 1.2.0", p.reload.citation_file
  end

  test "fetch_zenodo_file stores contents from archives api" do
    p = build_project
    stub_request(:get, p.archive_url(".zenodo.json")).to_return(status: 200, body: { contents: "{}" }.to_json)
    p.fetch_zenodo_file
    assert_equal "{}", p.reload.zenodo
  end

  test "fetch_readme stores contents via archive" do
    p = build_project
    stub_request(:get, p.archive_url("README.md")).to_return(status: 200, body: { contents: "# hello" }.to_json)
    p.fetch_readme
    assert_equal "# hello", p.reload.readme
  end

  test "fetch_readme falls back to raw url when archive fails" do
    p = build_project
    stub_request(:get, p.archive_url("README.md")).to_return(status: 500)
    stub_request(:get, p.raw_url("README.md")).to_return(status: 200, body: "# fallback")
    p.fetch_readme
    assert_equal "# fallback", p.reload.readme
  end

  test "fetch_codemeta stores contents via archive" do
    p = build_project
    stub_request(:get, p.archive_url("codemeta.json")).to_return(status: 200, body: { contents: '{"name":"x"}' }.to_json)
    p.fetch_codemeta
    assert_equal '{"name":"x"}', p.reload.codemeta
  end

  test "fetch_codemeta falls back to raw url when archive fails" do
    p = build_project
    stub_request(:get, p.archive_url("codemeta.json")).to_return(status: 500)
    stub_request(:get, p.raw_url("codemeta.json")).to_return(status: 200, body: '{"name":"y"}')
    p.fetch_codemeta
    assert_equal '{"name":"y"}', p.reload.codemeta
  end

  test "fetch_works looks up each doi against openalex" do
    p = build_project(readme: "See https://doi.org/10.1234/x")
    p.stubs(:readme_doi_urls).returns(["https://doi.org/10.1234/x"])
    stub_request(:get, "https://api.openalex.org/works/https://doi.org/10.1234/x")
      .to_return(status: 200, body: { id: "W1", counts_by_year: [] }.to_json)
    p.fetch_works
    assert_equal "W1", p.reload.works["https://doi.org/10.1234/x"]["id"]
  end

  # ---- check_url ----

  test "check_url updates url on redirect" do
    p = Project.create!(url: "https://github.com/old/name")
    stub_request(:get, "https://github.com/old/name").to_return(status: 301, headers: { "Location" => "https://github.com/new/name" })
    stub_request(:get, "https://github.com/new/name").to_return(status: 200)
    p.check_url
    assert_equal "https://github.com/new/name", p.reload.url
  end

  test "check_url destroys record when redirect target already exists" do
    Project.create!(url: "https://github.com/new/name")
    p = Project.create!(url: "https://github.com/old/name")
    stub_request(:get, "https://github.com/old/name").to_return(status: 301, headers: { "Location" => "https://github.com/new/name" })
    stub_request(:get, "https://github.com/new/name").to_return(status: 200)
    capture_io { p.check_url }
    refute Project.exists?(p.id)
  end

  # ---- find_or_create_host / find_or_create_owner ----

  test "find_or_create_host creates and associates host from repository data" do
    p = build_project
    assert_difference("Host.count", 1) { p.find_or_create_host }
    assert_equal "GitHub", p.reload.host.name
  end

  test "find_or_create_owner creates and associates owner from owner data" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    p = build_project(
      host: host,
      owner: { "login" => "NumPy", "name" => "NumPy" },
      science_score: 20
    )
    assert_difference("Owner.count", 1) { p.find_or_create_owner }
    owner = p.reload.owner_record
    assert_equal "numpy", owner.login
    assert_equal "NumPy", owner.name
    assert_equal 1, owner.projects_count
  end

  test "find_or_create_owner moves project counts between owners" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    old_owner = Owner.create!(host: host, login: "old-owner")
    project = build_project(
      host: host,
      owner_record: old_owner,
      owner: { "login" => "new-owner", "name" => "New Owner" },
      science_score: 20
    )

    project.find_or_create_owner

    assert_equal 0, old_owner.reload.projects_count
    assert_equal 1, project.reload.owner_record.projects_count
  end

  test "find_or_create_owner classifies the website used by science scoring" do
    create_research_organization_domain(
      "inbo.be",
      source: "ror",
      version: "sync",
      external_id: "https://ror.org/00j54wy13",
      organization_types: ["facility"]
    )
    ResearchOrganizationDomainMatcher.reset_cache!
    host = Host.create!(name: "GitHub", url: "https://github.com")
    project = build_project(
      host: host,
      owner: {
        "login" => "INBO",
        "name" => "Research Institute for Nature and Forest",
        "kind" => "organization",
        "website" => "https://www.inbo.be",
      }
    )

    project.find_or_create_owner
    result = ScienceScoreCalculator.new(project.reload).calculate

    assert project.owner_record.institutional?
    assert result[:breakdown][:has_institutional_owner][:present]
  ensure
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "find_or_create_owner reuses existing owner case-insensitively" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "numpy")
    p = build_project(host: host, owner: { "login" => "NumPy" })
    assert_no_difference("Owner.count") { p.find_or_create_owner }
    assert_equal "numpy", p.reload.owner_record.login
  end

  # ---- combine_keywords / ping ----

  test "combine_keywords merges repository topics and package keywords" do
    p = build_project(
      repository: repo_hash.merge("topics" => ["Astro", "python"]),
      packages: [{ "keywords" => ["astro", "science"] }]
    )
    p.combine_keywords
    assert_equal ["Astro", "python", "science"], p.reload.keywords
  end

  test "ping GETs each ping url" do
    p = build_project
    p.ping_urls.each { |u| stub_request(:get, u).to_return(status: 200) }
    p.ping
    p.ping_urls.each { |u| assert_requested :get, u }
  end

  test "http clients limit connection and request time" do
    p = build_project

    [p.http_client("https://github.com"), p.ecosystem_http_client("https://repos.ecosyste.ms")].each do |client|
      assert_equal 3, client.options.open_timeout
      assert_equal 10, client.options.timeout
    end
  end

  test "http client emits upstream metrics" do
    p = build_project
    stub_request(:get, "https://repos.example.org/project").to_return(status: 404)
    Appsignal.expects(:increment_counter)
      .with("upstream_http_requests", 1, host: "repos.example.org", status: "404")
    Appsignal.expects(:add_distribution_value)
      .with("upstream_http_duration", anything, host: "repos.example.org")

    p.http_client("https://repos.example.org/project").get
  end

  # ---- sync orchestration ----

  test "worker calls all sync stages and sets last_synced_at" do
    p = build_project
    Project.expects(:find_by_id).with(p.id).returns(p)
    %i[
      check_url fetch_repository find_or_create_host fetch_owner find_or_create_owner
      fetch_dependencies fetch_packages import_mentions fetch_readme combine_keywords
      fetch_commits fetch_events fetch_issue_stats sync_issues fetch_citation_file
      fetch_codemeta fetch_zenodo_file sync_releases update_committers
      update_keywords_from_contributors update_score update_science_score ping
    ].each { |m| p.expects(m).once }

    assert_nil p.last_synced_at
    SyncProjectWorker.new.perform(p.id)
    assert_not_nil p.reload.last_synced_at
  end

  test "slow sync timings include each stage" do
    p = build_project
    Rails.logger.expects(:info).with do |message|
      payload = JSON.parse(message)
      payload == {
        "event" => "project_sync_timing",
        "project_id" => p.id,
        "url" => p.url,
        "total_seconds" => 31.235,
        "slow_stages" => { "sync_issues" => 6.789 },
        "stages" => { "fetch_repository" => 1.235, "sync_issues" => 6.789 }
      }
    end

    p.log_sync_timings({ fetch_repository: 1.2345, sync_issues: 6.7894 }, 31.2346)
  end

  test "fast sync timings are not logged" do
    p = build_project
    Rails.logger.expects(:info).never

    p.log_sync_timings({ fetch_repository: 4.9996 }, 5.0)
  end

  test "sync creates an owner and increments its project count" do
    host = Host.create!(name: "GitHub", url: "https://github.com")
    project = build_project(
      host: host,
      owner: { "login" => "sync-owner", "name" => "Sync Owner", "kind" => "organization" }
    )
    %i[
      check_url fetch_repository find_or_create_host fetch_owner fetch_dependencies
      fetch_packages import_mentions fetch_readme combine_keywords fetch_commits
      fetch_events fetch_issue_stats sync_issues fetch_citation_file fetch_codemeta
      fetch_zenodo_file sync_releases update_committers update_keywords_from_contributors
      update_score ping
    ].each { |method| project.stubs(method).returns(nil) }
    project.stubs(:calculate_science_score_breakdown).returns(score: 20, breakdown: {})
    project.stubs(:matching_criteria?).returns(false)

    project.sync

    owner = project.reload.owner_record
    assert_equal "sync-owner", owner.login
    assert_equal 1, owner.projects_count
  end

  test "sync returns early for hidden owner" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "hidden", hidden: true)
    p = Project.new(url: "https://github.com/hidden/x", owner_record: owner)
    p.expects(:check_url).never
    assert_nil p.sync
  end

  test "fetch_brief stores trimmed brief output" do
    p = build_project(
      repository: repo_hash.merge("clone_url" => "https://github.com/numpy/numpy.git"),
      dependencies_indexed_at: 1.day.ago,
      dependencies_index_error: "old error"
    )
    output = {
      version: "0.11.0", languages: [{ name: "Python" }], package_managers: [],
      tools: { test: [{ name: "pytest" }] }, resources: {}, manifests: [], lines: {},
      dependencies: [{ name: "numpy" }], git: {}, stats: {}
    }.to_json
    Open3.expects(:capture3).with do |*args|
      assert_equal "https://github.com/numpy/numpy.git", args.last
      assert_includes args, "brief"
      assert_includes args, "timeout"
    end.returns([output, "", stub(success?: true)])

    p.fetch_brief
    assert_equal "0.11.0", p.reload.brief["version"]
    assert_equal "pytest", p.brief.dig("tools", "test", 0, "name")
    assert_equal "numpy", p.brief.dig("dependencies", 0, "name")
    refute p.brief.key?("git")
    assert_nil p.dependencies_indexed_at
    assert_nil p.dependencies_index_error
  end

  test "fetch_brief returns early when repository absent" do
    Open3.expects(:capture3).never
    assert_nil Project.new(url: "https://github.com/x/y").fetch_brief
  end

  test "fetch_brief handles missing binary" do
    p = build_project
    Open3.expects(:capture3).raises(Errno::ENOENT)
    assert_nothing_raised { p.fetch_brief }
    assert_nil p.brief
  end

  test "fetch_brief records error on non-zero exit" do
    p = build_project
    Open3.expects(:capture3).returns(["", "fatal: clone failed", stub(success?: false, exitstatus: 128)])
    assert_nothing_raised { p.fetch_brief }
    assert_equal "fatal: clone failed", p.reload.brief["error"]
    assert p.brief["attempted_at"].present?
  end

  test "fetch_brief records timeout error" do
    p = build_project
    Open3.expects(:capture3).returns(["", "", stub(success?: false, exitstatus: 124)])
    p.fetch_brief
    assert_equal "timeout", p.reload.brief["error"]
  end

  test "fetch_brief records error on parse failure" do
    p = build_project
    Open3.expects(:capture3).returns(["not json", "", stub(success?: true)])
    p.fetch_brief
    assert_match "parse:", p.reload.brief["error"]
  end

  test "sync_issues returns early when issues list response is not an array" do
    p = build_project
    stub_request(:get, p.issues_api_url).to_return(
      status: 200,
      body: { issues_url: "https://issues.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/issues" }.to_json
    )
    stub_request(:get, %r{issues\.ecosyste\.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/issues})
      .to_return(status: 200, body: { error: "rate limited" }.to_json)
    assert_nothing_raised { p.sync_issues }
    assert_equal 0, p.issues.count
  end

  test "sync_issues creates issue records from issues api" do
    p = build_project
    stub_request(:get, p.issues_api_url).to_return(
      status: 200,
      body: { issues_url: "https://issues.ecosyste.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/issues" }.to_json
    )
    stub_request(:get, %r{issues\.ecosyste\.ms/api/v1/hosts/GitHub/repositories/numpy/numpy/issues})
      .to_return(status: 200, body: [{ number: 1, title: "bug", state: "open" }].to_json)
    assert_difference("p.issues.count", 1) { p.sync_issues }
    assert_equal "bug", p.issues.first.title
  end
end
