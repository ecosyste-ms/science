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
