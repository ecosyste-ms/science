require "test_helper"

class ProjectMetadataTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(
      url: "https://github.com/test/metadata", science_score: 50, last_synced_at: Time.current,
      codemeta: {
        "name" => "Orbital analysis", "description" => "Exoplanet spectrometry",
        "softwareVersion" => "2.1", "license" => "MIT", "keywords" => ["Spectrometry", "orbits"],
        "datePublished" => "2025-03-04", "operatingSystem" => ["Linux", "macOS"],
        "author" => [{ "@type" => "Person", "givenName" => "Ada", "familyName" => "Lovelace" }]
      }.to_json,
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software.
        title: CFF title
        abstract: Orbital dynamics
        authors:
          - given-names: Grace
            family-names: Hopper
        keywords:
          - ORBITS
          - astrometry
      CFF
      zenodo: { "title" => "Zenodo title", "keywords" => ["astronomy"], "description" => "Space observations" }.to_json
    )
  end

  test "project API keeps citation links without normalized metadata" do
    get api_v1_project_url(@project)

    assert_response :success
    assert_not response.parsed_body.key?("software_metadata")
    assert response.parsed_body["csl_url"].present?
  end

  test "CodeMeta alone supports citation exports and export links" do
    @project.update!(citation_file: nil)

    get api_v1_project_url(@project)
    assert_response :success
    assert response.parsed_body["bibtex_url"].present?
    assert response.parsed_body["csl_url"].present?

    get export_project_url(@project, format: "bibtex")
    assert_response :success
    assert_includes response.body, "Orbital analysis"
    assert_includes response.body, "Lovelace, Ada"
    get export_project_url(@project, format: "apalike")
    assert_response :success
    assert_includes response.body, "Orbital analysis"

    get export_project_url(@project, format: "csl")
    assert_response :success
    assert_equal "application/vnd.citationstyles.csl+json", response.media_type
    result = JSON.parse(response.body)
    assert_equal "software", result["type"]
    assert_equal [{ "given" => "Ada", "family" => "Lovelace" }], result["author"]
    assert_equal [[2025, 3, 4]], result.dig("issued", "date-parts")
  end

  test "CSL preserves preferred citation authors and publication details" do
    @project.update!(citation_file: @project.citation_file + <<~CFF)
      preferred-citation:
        type: article
        title: A paper about the software
        authors:
          - name: Research Consortium
        journal: Research Journal
        year: 2024
        volume: 10
        issue: 2
        start: 20
        end: 29
    CFF

    get export_project_url(@project, format: "csl")

    assert_response :success
    result = JSON.parse(response.body)
    assert_equal "article-journal", result["type"]
    assert_equal "A paper about the software", result["title"]
    assert_equal [{ "literal" => "Research Consortium" }], result["author"]
    assert_equal "Research Journal", result["container-title"]
    assert_equal "20-29", result["page"]
    assert_equal [[2024]], result.dig("issued", "date-parts")
  end

  test "CodeMeta citations preserve literal names and organizations" do
    @project.update!(citation_file: nil, codemeta: {
      "name" => "Research software", "author" => ["Ada Lovelace", { "@type" => "Organization", "name" => "Research Group" }]
    }.to_json)

    get export_project_url(@project, format: "csl")

    assert_response :success
    assert_equal [{ "literal" => "Ada Lovelace" }, { "literal" => "Research Group" }], JSON.parse(response.body)["author"]
  end

  test "CodeMeta without citation authors does not produce an export" do
    @project.update!(citation_file: nil, codemeta: { "name" => "Research software" }.to_json)

    get export_project_url(@project, format: "csl")

    assert_response :not_found
  end

end
