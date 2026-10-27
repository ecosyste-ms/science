require "test_helper"

class ProjectSearchTest < ActionDispatch::IntegrationTest
  setup { IndexSoftwareSearchWorker.clear }
  teardown { IndexSoftwareSearchWorker.clear }

  def project(**attributes)
    Project.create!({ url: "https://github.com/main-search/#{SecureRandom.hex(8)}", science_score: 50 }.merge(attributes))
  end

  def search(query, **filters)
    get search_projects_url, params: { q: query }.merge(filters)
    assert_response :success
    assigns(:projects).map(&:id)
  end

  test "finds current names before indexing and preserves URL substring searches" do
    named = project(name: "Example Toolkit")
    url_match = project(url: "https://github.com/another-lab/Example-Toolkit")
    assert_nil named.search_indexed_at
    assert_equal [named.id], search("  EXAMPLE TOOLKIT  ")
    assert_equal [url_match.id], search("ANOTHER-LAB/Example")
  end

  test "includes low positive scores in web search but retains the API scientific threshold" do
    low = project(name: "Specific Package", science_score: 1,
      packages: [{ "name" => "DistinctivePackage", "purl" => "pkg:pypi/distinctivepackage" }])
    project(name: "Specific Package", science_score: 0)
    project(name: "Specific Package", science_score: nil)
    high = project(name: "Specific Package")
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "hidden-search")
    project(name: "Specific Package", owner_record: owner)
    owner.update!(hidden: true)
    IndexSoftwareSearchWorker.drain

    assert_equal [high.id, low.id], search("Specific Package")
    assert_equal [low.id], search("distinctivepackage")
    get "/api/v1/software/lookup", params: { q: "Specific Package" }
    assert_equal [high.id], response.parsed_body.fetch("projects").pluck("project_id")
  end

  test "finds published packages and aliases from both metadata and stored repository history" do
    found = project(repository: { "previous_names" => ["old/PreviousToolkit"] },
      codemeta: { "alternateName" => ["Alternative Toolkit"] }.to_json)
    found.repository_aliases.create!(url: "https://github.com/former/RecordedToolkit")
    registry = PackageRegistry.create!(name: "pypi.org", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    package = registry.packages.create!(name: "PublishedToolkit", purl: "pkg:pypi/publishedtoolkit", published_by_project: found)
    IndexSoftwareSearchWorker.drain

    ["publishedtoolkit", "PREVIOUSTOOLKIT", "recordedtoolkit", "Alternative Toolkit",
      "https://github.com/old/PreviousToolkit", "https://github.com/former/RecordedToolkit"].each do |query|
      assert_equal [found.id], search(query), query
    end
    package.update!(name: "RenamedPackage")
    IndexSoftwareSearchWorker.drain
    assert_empty search("PublishedToolkit")
    assert_equal [found.id], search("RenamedPackage")
  end

  test "literal punctuation and Unicode names do not expand into wildcard queries" do
    literal = project(name: "100%_Café")
    project(name: "100xxCafe")
    IndexSoftwareSearchWorker.drain
    assert_equal [literal.id], search("0%_")
    assert_equal [literal.id], search("CAFE\u0301")
    assert_empty search("' OR 1=1 --")
    assert_empty search("https://[invalid")
  end

  test "name matches retain keyword and language filters" do
    matching = project(name: "Filtered Toolkit", keywords: ["bioinformatics"], repository: { "language" => "R" })
    project(name: "Filtered Toolkit", keywords: ["bioinformatics"], repository: { "language" => "Python" })
    project(name: "Filtered Toolkit", keywords: ["visualization"], repository: { "language" => "R" })
    assert_equal [matching.id], search("Filtered Toolkit", keywords: "bioinformatics", language: "R")
  end

  test "multiple matching fields do not duplicate projects and tied pages have stable ordering" do
    projects = 23.times.map do |i|
      project(url: "https://github.com/shared-toolkit/project-#{i}", name: "Shared Toolkit", score: 5,
        packages: [{ "name" => "Shared Toolkit" }], codemeta: { "alternateName" => ["Shared Toolkit"] }.to_json)
    end
    IndexSoftwareSearchWorker.drain
    assert_equal projects.first(20).map(&:id), search("Shared Toolkit")
    assert_equal projects.drop(20).map(&:id), search("Shared Toolkit", page: 2)
    assert_equal projects.first(20).map(&:id), search("Shared Toolkit")
  end

  test "confirmed Wikidata aliases remain separate candidate projects and expose provenance" do
    first = project
    second = project
    ambiguous = project
    record = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q5971368", status: "ok",
      retrieved_at: Time.current, next_refresh_at: 1.day.from_now,
      metadata: { "labels" => { "en" => { "language" => "en", "value" => "Symbolic Mathematics" } },
        "aliases" => { "en" => [{ "language" => "en", "value" => "Symbolic Python" }] } })
    [first, second, ambiguous].each do |candidate|
      candidate.project_external_software_records.create!(external_software_record: record,
        match_status: candidate == ambiguous ? "ambiguous" : "matched", relationship: "source_code_repository",
        evidence: [{ "property" => "P1324", "repository_url" => candidate.url }])
    end
    IndexSoftwareSearchWorker.drain
    assert_equal [first.id, second.id], search("SYMBOLIC PYTHON")
    assert_equal [first.id, second.id], search("Symbolic Mathematics")

    get "/api/v1/software/lookup", params: { q: "Symbolic Python" }
    evidence = response.parsed_body.fetch("projects").first.fetch("seeds").sole.fetch("name_evidence")
    assert_equal "registry_alias", evidence.fetch("kind")
    assert_equal "en", evidence.fetch("language")
    assert_equal record.id, evidence.fetch("external_software_record_id")
    assert_equal first.project_external_software_records.sole.id, evidence.fetch("project_external_software_record_id")
    assert_equal "https://www.wikidata.org/wiki/Q5971368", evidence.fetch("record_url")
    assert_equal "P1324", evidence.fetch("evidence").sole.fetch("property")

    record.update!(status: "error")
    IndexSoftwareSearchWorker.drain
    assert_equal [first.id, second.id], search("Symbolic Python")
    record.update!(status: "missing")
    assert_not_empty IndexSoftwareSearchWorker.jobs
    IndexSoftwareSearchWorker.drain
    refute_includes first.reload.search_names, "symbolic python"
    assert_empty search("Symbolic Python")
  end
end
