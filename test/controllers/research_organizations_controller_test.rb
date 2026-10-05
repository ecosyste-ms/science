require "test_helper"
require "tempfile"
require "rake"
require "yaml"

class ResearchOrganizationsControllerTest < ActionDispatch::IntegrationTest
  ROOT = "00za53h95"
  CHILD = "029pp9z10"
  UNLINKED = "02wt5sv47"

  setup do
    ResearchOrganizationDomainMatcher.reset_cache!
    @host = Host.create!(name: "GitHub", url: "https://github.com")
    source = JSON.parse(Rails.root.join("test/fixtures/files/ror_johns_hopkins.json").read)
    root = source.merge("relationships" => [{ "id" => "https://ror.org/#{CHILD}", "type" => "child", "label" => "Lab" }])
    child = source.deep_dup.merge("id" => "https://ror.org/#{CHILD}", "domains" => ["lab.edu"], "links" => [],
      "names" => [{ "value" => "Research Lab", "types" => ["ror_display"], "lang" => "en" }],
      "relationships" => [{ "id" => "https://ror.org/#{ROOT}", "type" => "child", "label" => "University" }])
    unlinked = source.deep_dup.merge("id" => "https://ror.org/#{UNLINKED}", "domains" => [], "links" => [],
      "status" => "inactive", "relationships" => [])
    unlinked["locations"] << { "geonames_details" => { "country_code" => "FR", "country_name" => "France" } }
    Tempfile.create(["ror-controller", ".json"]) do |file|
      file.write([root, child, unlinked].to_json)
      file.flush
      RorResearchOrganizationImporter.import_file!(file.path, source_version: "controller-test", minimum_records: 1)
    end
    @root = ResearchOrganization.find_by!(ror_id: "https://ror.org/#{ROOT}")
    @child = ResearchOrganization.find_by!(ror_id: "https://ror.org/#{CHILD}")
    @account = Owner.create!(host: @host, login: "jhu", kind: "organization", website: "https://www.jhu.edu")
    @child_account = Owner.create!(host: @host, login: "lab", kind: "organization", website: "https://lab.edu")
    @project = Project.create!(url: "https://github.com/jhu/science", host: @host, owner_record: @account,
      name: "Science", science_score: 42)
    @child_project = Project.create!(url: "https://github.com/lab/science", host: @host, owner_record: @child_account,
      name: "Child science", science_score: 80)
    @registry = PackageRegistry.create!(name: "PyPI", url: "https://pypi.org", ecosystem: "pypi", purl_type: "pypi")
    @package = Package.create!(package_registry: @registry, name: "jhu-science", purl: "pkg:pypi/jhu-science",
      published_by_project: @project)
  end

  teardown do
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "institution search matches aliases and country in HTML and API after a real record import" do
    get api_v1_research_organizations_path, params: { q: "jHu", country: "us" }
    assert_response :success
    assert_equal [ROOT], response.parsed_body.pluck("id")
    entry = response.parsed_body.sole
    assert_equal 1, entry["linked_accounts_count"]
    assert_equal "controller-test", entry.dig("source", "version")
    assert_equal "1", response.headers["total-count"]
    get research_organizations_path, params: { q: "jHu", country: "us" }
    assert_response :success
    assert_select "a[href=?]", research_organization_path(ROOT), text: "Johns Hopkins University"
    get api_v1_research_organizations_path, params: { country: "fr" }
    assert_empty response.parsed_body
    get api_v1_research_organizations_path, params: { country: "fr", include_unlinked: true }
    assert_equal [UNLINKED], response.parsed_body.pluck("id")
    assert_equal "inactive", response.parsed_body.sole["status"]
    get research_organizations_path, params: { country: "fr", include_unlinked: true }
    assert_response :success
    assert_select "a[href=?]", research_organization_path(UNLINKED)
  end

  test "search treats wildcard characters quotes and backslashes literally" do
    @root.metadata["names"] << { "value" => 'A_% "quoted" \\Lab', "types" => ["alias"] }
    @root.save!
    ['_%', '"quoted"', '\\Lab'].each do |query|
      get api_v1_research_organizations_path, params: { q: query }
      assert_response :success
      assert_equal [ROOT], response.parsed_body.pluck("id"), query
    end
  end

  test "profile counts and lists use confirmed visible accounts and scientific projects" do
    Project.create!(url: "https://github.com/jhu/non-science", owner_record: @account, science_score: 19.9)
    ambiguous = Owner.create!(host: @host, login: "ambiguous", kind: "organization")
    ambiguous.owner_research_organizations.create!(research_organization: @root, source: "ror", match_method: "ror_domain",
      match_status: "ambiguous", observed_at: Time.current, evidence: { "matched_domain" => "shared.edu" })
    hidden = Owner.create!(host: @host, login: "hidden", kind: "organization", website: "https://jhu.edu")
    hidden_project = Project.create!(url: "https://github.com/hidden/science", owner_record: hidden, science_score: 90)
    hidden.update_column(:hidden, true)
    assert_not Project.visible.exists?(hidden_project.id)
    get api_v1_research_organization_path(ROOT)
    assert_response :success
    assert_equal({ "organizations" => 1, "accounts" => 1, "scientific_projects" => 1, "packages" => 1,
      "ambiguous_accounts" => 1 }, response.parsed_body["counts"])
    assert_equal false, response.parsed_body.dig("coverage", "ambiguous_links_included")
    get owners_api_v1_research_organization_path(ROOT)
    assert_response :success
    assert_equal [@account.id], response.parsed_body.pluck("id")
    assert_equal "ror_domain", response.parsed_body.sole["organization_matches"].sole["match_method"]
    assert_equal 1, response.parsed_body.sole["scientific_projects_count"]
    assert_not response.parsed_body.sole.key?("email")
    get projects_api_v1_research_organization_path(ROOT)
    assert_response :success
    assert_equal [@project.id], response.parsed_body.pluck("id")
    get packages_api_v1_research_organization_path(ROOT)
    assert_response :success
    assert_equal [@package.id], response.parsed_body.pluck("id")
    assert_equal @project.id, response.parsed_body.sole.dig("published_by_project", "id")
    get research_organization_path(ROOT)
    assert_response :success
    assert_select "#project_#{@project.id}"
    assert_select "#project_#{@child_project.id}", count: 0
    get owners_research_organization_path(ROOT)
    assert_response :success
    assert_select "a[href=?]", host_owner_path(@host.name, @account.login)
    assert_select "a[href=?]", host_owner_path(@host.name, ambiguous.login), count: 0
    get packages_research_organization_path(ROOT)
    assert_response :success
    assert_select "h2", @package.name
  end

  test "descendant scopes handle cycles and count multi-institution account links once" do
    @account.owner_research_organizations.create!(research_organization: @child, source: "manual", match_method: "manual",
      match_status: "matched", observed_at: Time.current, evidence: { "basis" => "confirmed joint account" })
    get api_v1_research_organization_path(ROOT), params: { include_descendants: true }
    assert_response :success
    assert_equal 2, response.parsed_body.dig("counts", "organizations")
    assert_equal 2, response.parsed_body.dig("counts", "accounts")
    assert_equal 2, response.parsed_body.dig("counts", "scientific_projects")
    assert_equal 1, response.parsed_body.dig("counts", "packages")
    get owners_api_v1_research_organization_path(ROOT), params: { include_descendants: true }
    assert_equal [@account.id, @child_account.id], response.parsed_body.pluck("id")
    assert_equal 2, response.parsed_body.first["organization_matches"].size
    get projects_api_v1_research_organization_path(ROOT), params: { include_descendants: true }
    assert_equal [@child_project.id, @project.id], response.parsed_body.pluck("id")
    get research_organization_path(ROOT), params: { include_descendants: true }
    assert_response :success
    assert_select "#project_#{@project.id}", count: 1
    assert_select "#project_#{@child_project.id}", count: 1
    assert_select "a[href=?]", packages_research_organization_path(ROOT, include_descendants: true)
  end

  test "retained records expose source age and pending records are not published" do
    old_import = @root.current_import
    old_import.update!(current: false)
    ResearchOrganizationImport.create!(source_version: "new", checksum: "new", retrieved_at: Time.current,
      current: true, completed_at: Time.current)
    get api_v1_research_organization_path(ROOT)
    assert_response :success
    assert_equal false, response.parsed_body.dig("source", "current")
    get research_organization_path(ROOT)
    assert_response :success
    assert_select ".alert-warning", /earlier ROR release/
    pending = ResearchOrganization.create!(ror_id: "https://ror.org/01an7q238")
    [research_organization_path(pending), api_v1_research_organization_path(pending)].each do |path|
      get path
      assert_response :not_found
    end
  end

  test "invalid filters return 400 in HTML and API" do
    [{ country: "USA" }, { include_unlinked: "yes" }, { q: "a" * 201 }, { per_page: 0 }, { per_page: "lots" }].each do |params|
      [research_organizations_path, api_v1_research_organizations_path].each do |path|
        get path, params: params
        assert_response :bad_request
      end
    end
    [research_organization_path(ROOT), api_v1_research_organization_path(ROOT)].each do |path|
      get path, params: { include_descendants: "yes" }
      assert_response :bad_request
    end
  end

  test "pagination is bounded stable and includes API headers" do
    22.times do |index|
      @account.owner_research_organizations.create!(research_organization: ResearchOrganization.create!(
        ror_id: "https://ror.org/0aaaaaa#{index.to_s.rjust(2, '0')}", current_import: @root.current_import,
        metadata: { "status" => "active", "names" => [{ "value" => "Same institution", "types" => ["ror_display"] }] }),
        source: "manual", match_method: "manual", match_status: "matched", observed_at: Time.current)
    end
    get api_v1_research_organizations_path
    assert_equal 20, response.parsed_body.size
    first_page = response.parsed_body.pluck("id")
    assert_includes response.headers["link"], 'rel="next"'
    get api_v1_research_organizations_path, params: { page: 2 }
    assert_equal 4, response.parsed_body.size
    assert_empty first_page & response.parsed_body.pluck("id")
    get api_v1_research_organizations_path, params: { per_page: 999 }
    assert_equal "100", response.headers["page-items"]
    get research_organizations_path, params: { page: 2 }
    assert_response :success
  end

  test "legacy domain account browse has API parity including accounts without ROR links" do
    legacy = Owner.create!(host: @host, login: "legacy", kind: "organization")
    legacy.update_column(:institutional_domain, "legacy.edu")
    get accounts_api_v1_research_organizations_path
    assert_response :success
    assert_includes response.parsed_body.pluck("id"), legacy.id
    assert_empty response.parsed_body.find { |entry| entry["id"] == legacy.id }["organization_matches"]
    get research_organization_accounts_path
    assert_response :success
    assert_select "a[href=?]", host_owner_path(@host.name, legacy.login)
  end

  test "OpenAPI schemas describe actual institution responses" do
    @openapi = YAML.safe_load(Rails.root.join("openapi/api/v1/openapi.yaml").read)
    assert_equal "1.0.0", @openapi.dig("info", "version")
    endpoints = {
      "/research_organizations" => api_v1_research_organizations_path,
      "/research_organizations/accounts" => accounts_api_v1_research_organizations_path,
      "/research_organizations/{id}" => api_v1_research_organization_path(ROOT),
      "/research_organizations/{id}/owners" => owners_api_v1_research_organization_path(ROOT),
      "/research_organizations/{id}/packages" => packages_api_v1_research_organization_path(ROOT)
    }
    endpoints.each do |documented_path, path|
      get path
      assert_response :success
      schema = @openapi.dig("paths", documented_path, "get", "responses", "200", "content", "application/json", "schema")
      assert_schema(schema, response.parsed_body)
      headers = @openapi.dig("paths", documented_path, "get", "responses", "200", "headers") || {}
      headers.each do |name, definition|
        header = @openapi.dig("components", "headers", definition.fetch("$ref").split("/").last)
        value = response.headers[name]
        value = Integer(value) if header.dig("schema", "type") == "integer"
        assert_schema(header.fetch("schema"), value)
      end
    end
    assert_equal "#/components/schemas/Project", @openapi.dig("paths", "/research_organizations/{id}/projects", "get", "responses", "200", "content", "application/json", "schema", "items", "$ref")
  end

  def assert_schema(schema, value)
    schema = @openapi.dig("components", "schemas", schema["$ref"].split("/").last) if schema["$ref"]
    return if value.nil? && schema["nullable"]
    if schema["allOf"]
      schema["allOf"].each { |part| assert_schema(part, value) }
    elsif schema["type"] == "object"
      assert_kind_of Hash, value
      schema.fetch("required", []).each { |key| assert value.key?(key), key }
      schema.fetch("properties", {}).each { |key, part| assert_schema(part, value[key]) if value.key?(key) }
    elsif schema["type"] == "array"
      assert_kind_of Array, value
      value.each { |entry| assert_schema(schema.fetch("items"), entry) }
    else
      expected = { "string" => String, "integer" => Integer, "number" => Numeric, "boolean" => [TrueClass, FalseClass] }.fetch(schema["type"])
      assert Array(expected).any? { |type| value.is_a?(type) }, "#{value.inspect} must be #{schema['type']}"
    end
    assert_includes schema["enum"], value if schema["enum"]
  end
end
