require "test_helper"

class Api::V1::SearchSeedsTest < ActionDispatch::IntegrationTest
  test "returns software seeds and citation targets with source evidence" do
    project = create_project(
      name: "ClimateLab",
      repository: {
        "homepage" => "https://climate.example/Docs",
        "previous_names" => ["original/ClimateTools"],
      },
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software
        title: Climate Lab
        authors:
          - name: Climate Team
        doi: 10.1234/Software
        preferred-citation:
          type: article
          title: Climate modelling
          authors:
            - name: Climate Team
          doi: 10.1234/Paper
        references:
          - type: software
            title: Other Software
            doi: 10.1234/Unrelated
            repository-code: https://github.com/other/software
      CFF
      codemeta: {
        "name" => "ClimateLab",
        "alternateName" => ["Climate-Lab", "CLab"],
        "identifier" => "https://doi.org/10.1234/Code",
        "referencePublication" => { "@id" => "https://doi.org/10.1234/Methods" },
        "relatedLink" => "https://github.com/other/related",
      }.to_json,
      zenodo: {
        "doi" => "10.1234/Archive",
        "related_identifiers" => [
          { "scheme" => "DOI", "relation" => "isDocumentedBy", "identifier" => "10.1234/Documentation" },
          { "scheme" => "doi", "relation" => "references", "identifier" => "10.1234/Other" },
        ],
      }.to_json,
      joss_metadata: { "doi" => "10.1234/Joss" }
    )

    get search_seeds_api_v1_projects_url

    assert_response :success
    record = response.parsed_body.sole
    assert_equal project.id, record.fetch("project_id")
    assert_equal project.url, record.fetch("repository_url")
    assert_empty record.fetch("packages")
    seeds = record.fetch("seeds")
    assert_seed seeds, "name", "climatelab", "project.name", "software", value: "ClimateLab"
    assert_seed seeds, "name", "climate-lab", "codemeta.alternateName", "software"
    assert_seed seeds, "name", "climatetools", "repository.previous_names", "software", value: "ClimateTools"
    assert_seed seeds, "homepage_url", "https://climate.example/Docs", "repository.homepage", "software"
    assert_seed seeds, "doi", "10.1234/software", "citation_cff.doi", "software"
    assert_seed seeds, "doi", "10.1234/paper", "citation_cff.preferred-citation.doi", "preferred_citation"
    assert_seed seeds, "doi", "10.1234/code", "codemeta.identifier", "software"
    assert_seed seeds, "doi", "10.1234/methods", "codemeta.referencePublication.@id", "publication"
    assert_seed seeds, "doi", "10.1234/archive", "zenodo.doi", "software"
    assert_seed seeds, "doi", "10.1234/documentation", "zenodo.related_identifiers.isDocumentedBy", "publication"
    assert_seed seeds, "doi", "10.1234/joss", "joss_metadata.doi", "publication"
    assert seeds.none? { |seed| seed.fetch("normalized_value").match?(/unrelated|other|related/) }
  end

  test "keeps registry identities and stored package names without local IDs" do
    project = create_project(packages: [
      { "name" => "climateLab", "purl" => "pkg:pypi/climatelab@1.0", "homepage" => "https://old.example/" },
      { "name" => "ClimateWithoutPurl", "ecosystem" => "conda" },
      { "name" => "ClimateLegacy", "ecosystem" => "conda", "purl" => "pkg:conda/climate-legacy" },
    ])
    pypi = create_registry("pypi", "pypi.org")
    cran = create_registry("cran", "cran.r-project.org")
    first = Package.create!(
      name: "ClimateLab", purl: "pkg:pypi/climatelab", package_registry: pypi,
      published_by_project: project, metadata: { "homepage" => "https://climate.example/" }
    )
    second = Package.create!(
      name: "ClimateLab", purl: "pkg:cran/ClimateLab", package_registry: cran,
      published_by_project: project
    )

    get search_seeds_api_v1_projects_url

    assert_response :success
    packages = response.parsed_body.sole.fetch("packages")
    assert_equal [first.id, second.id, nil, nil], packages.map { |package| package.fetch("package_id") }
    assert_equal %w[pypi cran conda conda], packages.map { |package| package.fetch("ecosystem") }
    assert_equal "pypi.org", packages.first.fetch("registry")
    assert_seed packages.first.fetch("seeds"), "name", "climatelab", "package.name", "software", value: "ClimateLab"
    assert_seed packages.first.fetch("seeds"), "homepage_url", "https://climate.example/", "package.homepage", "software"
    assert_seed packages.first.fetch("seeds"), "name", "climatelab", "project.packages[0].name", "software", value: "climateLab"
    assert_seed packages.first.fetch("seeds"), "homepage_url", "https://old.example/", "project.packages[0].homepage", "software"
    assert_seed packages[2].fetch("seeds"), "name", "climatewithoutpurl", "project.packages[1].name", "software"
    assert_seed packages.last.fetch("seeds"), "name", "climatelegacy", "project.packages[2].name", "software"
  end

  test "keeps same-name projects and forks separate and includes archived projects" do
    upstream = create_project(name: "Stats", repository: { "archived" => true })
    fork = create_project(name: "Stats", repository: { "fork" => true })
    upstream.repository_aliases.create!(url: "https://github.com/old/stats")

    get search_seeds_api_v1_projects_url

    assert_response :success
    records = response.parsed_body
    assert_equal [upstream.id, fork.id], records.map { |record| record.fetch("project_id") }
    records.each do |record|
      assert_seed record.fetch("seeds"), "name", "stats", "project.name", "software"
    end
    assert records.last.fetch("seeds").none? { |seed| seed["source"] == "repository.previous_names" }
  end

  test "paginates visible scientific projects in ID order without requiring packages" do
    first = create_project(science_score: Project::SCIENCE_SCORE_THRESHOLD)
    second = create_project
    create_project(science_score: Project::SCIENCE_SCORE_THRESHOLD - 1)
    hidden = create_project
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "hidden", hidden: true)
    hidden.update_columns(owner_id: owner.id)

    get search_seeds_api_v1_projects_url, params: { per_page: 1 }
    assert_response :success
    assert_equal [first.id], response.parsed_body.pluck("project_id")
    assert_includes response.headers.fetch("link"), 'rel="next"'
    assert_nil response.headers["total-count"]

    get search_seeds_api_v1_projects_url, params: { per_page: 1, page: 2 }
    assert_response :success
    assert_equal [second.id], response.parsed_body.pluck("project_id")
    assert_not_includes response.headers.fetch("link"), 'rel="next"'

    get search_seeds_api_v1_projects_url, params: { per_page: 1, page: 3 }
    assert_response :success
    assert_empty response.parsed_body
  end

  test "caps requested page size" do
    create_project

    get search_seeds_api_v1_projects_url, params: { per_page: 3000 }

    assert_response :success
    assert_equal "100", response.headers.fetch("page-items")
  end

  test "ignores malformed optional metadata and unsafe URLs" do
    project = create_project(
      name: "R++",
      repository: { "homepage" => "https://user:secret@example.org/", "previous_names" => "invalid" },
      citation_file: "cff-version: 1.2.0\ntitle: [",
      codemeta: "[]", zenodo: "{invalid", joss_metadata: [],
      packages: [nil, "invalid", { "name" => "R++", "purl" => "bad purl", "homepage" => "javascript:alert(1)" }]
    )

    get search_seeds_api_v1_projects_url

    assert_response :success
    record = response.parsed_body.sole
    assert_seed record.fetch("seeds"), "name", "r++", "project.name", "software", value: "R++"
    assert_equal %w[name repository_url], record.fetch("seeds").pluck("type")
    assert_nil record.fetch("packages").sole.fetch("purl")
    assert_equal ["name"], record.fetch("packages").sole.fetch("seeds").pluck("type")
    assert_equal project.id, record.fetch("project_id")
  end

  test "exposes BibTeX citation targets without treating them as software identifiers" do
    create_project(citation_file: '@article{climate, title={Climate}, doi={10.1234/climate}}')

    get search_seeds_api_v1_projects_url

    assert_response :success
    assert_seed response.parsed_body.sole.fetch("seeds"), "doi", "10.1234/climate", "citation_bib.doi", "citation"
  end

  def create_project(**attributes)
    Project.create!({ url: "https://github.com/seeds/#{SecureRandom.hex(6)}", science_score: 50 }.merge(attributes))
  end

  def create_registry(ecosystem, name)
    PackageRegistry.create!(name: name, url: "https://#{name}", ecosystem: ecosystem, purl_type: ecosystem)
  end

  def assert_seed(seeds, type, normalized_value, source, relation, value: nil)
    match = seeds.find do |seed|
      seed.values_at("type", "normalized_value", "source", "relation") == [type, normalized_value, source, relation]
    end
    assert match, "Missing #{[type, normalized_value, source, relation].inspect} in #{seeds.inspect}"
    assert_equal value, match.fetch("value") if value
  end
end
