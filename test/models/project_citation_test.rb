require "test_helper"

class ProjectCitationTest < ActiveSupport::TestCase
  test "file_name accessors read from repository metadata files" do
    p = Project.new(url: "https://github.com/x/y", repository: {
      "metadata" => { "files" => { "citation" => "CITATION.cff", "codemeta" => "codemeta.json", "zenodo" => ".zenodo.json" } },
    })
    assert_equal "CITATION.cff", p.citation_file_name
    assert_equal "codemeta.json", p.codemeta_file_name
    assert_equal ".zenodo.json", p.zenodo_file_name
  end

  test "file_name accessors return nil when repository metadata missing" do
    p = Project.new(url: "https://github.com/x/y")
    assert_nil p.citation_file_name
    assert_nil p.codemeta_file_name
    assert_nil p.zenodo_file_name
  end

  test "codemeta_json parses valid json and returns nil on parse error" do
    p = Project.new(url: "https://github.com/x/y", codemeta: '{"name":"foo"}')
    assert_equal "foo", p.codemeta_json["name"]

    p.codemeta = "{not json"
    capture_io { assert_nil p.codemeta_json }
  end

  test "zenodo_json parses valid json and returns nil on parse error" do
    p = Project.new(url: "https://github.com/x/y", zenodo: '{"title":"foo"}')
    assert_equal "foo", p.zenodo_json["title"]

    p.zenodo = "{not json"
    capture_io { assert_nil p.zenodo_json }
  end

  test "citation_cff returns nil when citation_file blank" do
    assert_nil Project.new(url: "https://github.com/x/y").citation_cff
  end

  test "citation_cff ignores non-CFF citation content" do
    project = Project.new(
      url: "https://github.com/x/y",
      repository: {
        "metadata" => { "files" => { "citation" => "CITATION.bib" } },
      },
      citation_file: "@article{paper, doi = {10.1000/example}}"
    )

    assert_nil project.citation_cff
    assert_empty project.citation_cff_preferred_doi_candidates
  end

  test "extracts DOI fields and resolver URLs from BibTeX citation content" do
    project = Project.new(
      url: "https://github.com/x/y",
      citation_file: <<~BIBTEX
        @article{first,
          doi = {10.1000/bibtex-field},
          url = {https://doi.org/10.1000/bibtex-field}
        }
        @software{second,
          DOI = "10.1000/bibtex-quoted"
        }
        @misc{third,
          url = {https://doi.org/10.1000/bibtex-url}
        }
      BIBTEX
    )

    assert_equal [
      { value: "10.1000/bibtex-field", source: "citation_bib.doi" },
      { value: "10.1000/bibtex-quoted", source: "citation_bib.doi" },
      {
        value: "https://doi.org/10.1000/bibtex-field",
        source: "citation_bib.doi_url",
      },
      {
        value: "https://doi.org/10.1000/bibtex-url",
        source: "citation_bib.doi_url",
      },
    ], project.citation_bib_doi_candidates
  end

  test "returns no CFF DOI candidates when preferred citation is absent" do
    project = Project.new(
      url: "https://github.com/x/y",
      citation_file: <<~CFF
        cff-version: 1.2.0
        message: Cite this software.
        title: Example software
        authors:
          - family-names: Doe
            given-names: Jane
      CFF
    )

    assert_empty project.citation_cff_preferred_doi_candidates
  end

  test "extracts preferred citation DOI candidates from CITATION.cff" do
    project = Project.new(
      url: "https://github.com/x/y",
      citation_file: <<~CFF
        cff-version: 1.2.0
        message: Cite the paper below.
        title: Example software
        authors:
          - family-names: Doe
            given-names: Jane
        preferred-citation:
          type: article
          title: Example paper
          authors:
            - family-names: Doe
              given-names: Jane
          doi: 10.1000/cff-paper
          identifiers:
            - type: doi
              value: 10.1000/cff-identifier
      CFF
    )

    assert_equal [
      {
        value: "10.1000/cff-paper",
        source: "citation_cff.preferred-citation.doi",
      },
      {
        value: "10.1000/cff-identifier",
        source: "citation_cff.preferred-citation.identifiers",
      },
    ], project.citation_cff_preferred_doi_candidates
  end

  test "extracts CodeMeta reference publication DOI candidates with field provenance" do
    project = Project.new(
      url: "https://github.com/x/y",
      codemeta: {
        "referencePublication" => [
          "https://doi.org/10.1000/codemeta-paper",
          {
            "@type" => "ScholarlyArticle",
            "identifier" => {
              "@type" => "PropertyValue",
              "propertyID" => "DOI",
              "value" => "10.1000/codemeta-identifier",
            },
          },
        ],
      }.to_json
    )

    assert_equal [
      {
        value: "https://doi.org/10.1000/codemeta-paper",
        source: "codemeta.referencePublication",
      },
      {
        value: "10.1000/codemeta-identifier",
        source: "codemeta.referencePublication.identifier.value",
      },
    ], project.codemeta_reference_publication_doi_candidates
  end

  test "extracts only documented-by DOI identifiers from Zenodo metadata" do
    project = Project.new(
      url: "https://github.com/x/y",
      zenodo: {
        "related_identifiers" => [
          {
            "scheme" => "doi",
            "identifier" => "10.1000/zenodo-paper",
            "relation" => "isDocumentedBy",
          },
          {
            "scheme" => "doi",
            "identifier" => "10.1000/zenodo-data",
            "relation" => "isSupplementTo",
          },
          {
            "scheme" => "url",
            "identifier" => "https://doi.org/10.1000/not-a-doi-scheme",
            "relation" => "isDocumentedBy",
          },
        ],
      }.to_json
    )

    assert_equal [{
      value: "10.1000/zenodo-paper",
      source: "zenodo.related_identifiers.isDocumentedBy",
    }], project.zenodo_documentation_doi_candidates
  end

  test "person_to_codemeta handles Person with orcid and affiliation" do
    p = Project.new(url: "https://github.com/x/y")
    person = CFF::Person.new
    person.given_names = "Jane"
    person.family_names = "Doe"
    person.email = "jane@example.com"
    person.orcid = "https://orcid.org/0000-0000-0000-0000"
    person.affiliation = "Example University"

    result = p.person_to_codemeta(person)
    assert_equal "Person", result["@type"]
    assert_equal "Jane Doe", result["name"]
    assert_equal "Jane", result["givenName"]
    assert_equal "Doe", result["familyName"]
    assert_equal "jane@example.com", result["email"]
    assert_equal "https://orcid.org/0000-0000-0000-0000", result["@id"]
    assert_equal "Example University", result["affiliation"]
  end

  test "person_to_codemeta handles Entity as Organization" do
    p = Project.new(url: "https://github.com/x/y")
    entity = CFF::Entity.new("Example Org")

    result = p.person_to_codemeta(entity)
    assert_equal "Organization", result["@type"]
    assert_equal "Example Org", result["name"]
    refute result.key?("givenName")
  end

  test "export_citation returns nil for unknown format" do
    p = Project.new(url: "https://github.com/x/y", citation_file: "cff-version: 1.2.0\ntitle: t\n")
    assert_nil p.export_citation(format: "xml")
  end
end
