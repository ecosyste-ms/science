require "test_helper"

class Api::V1::SearchSeedIdentifiersTest < ActionDispatch::IntegrationTest
  setup { IndexSoftwareSearchWorker.jobs.clear }
  teardown { IndexSoftwareSearchWorker.jobs.clear }

  test "exports confirmed software identifiers and resolves shared identifiers with their evidence" do
    first = project("first")
    second = project("second")
    ambiguous = project("ambiguous")
    record = identifier(first, "rrid", "SCR_002285")
    second.project_external_software_records.create!(external_software_record: record,
      relationship: "source_code_repository", match_status: "matched", evidence: [{ "source_field" => "distributions.alternate" }])
    ambiguous.project_external_software_records.create!(external_software_record: record,
      relationship: "source_code_repository", match_status: "ambiguous")
    duplicate = identifier(first, "rrid", "RRID:SCR_002285")
    kinds = { "wikidata" => "Q123", "biotools" => "ClimateTools", "ascl" => "2401.123", "swmath" => "123", "doi" => "10.1234/Software" }
    kinds.each { |scheme, value| identifier(first, scheme, value) }
    identifier(first, "rrid", "SCR_000000")
    identifier(first, "rrid", "SCR_123456", status: "missing")
    identifier(first, "rrid", "SCR_123457", retrieved_at: nil)
    identifier(first, "rrid", "SCR_123458", match_status: "ambiguous")
    identifier(first, "doi", "10.1234/Paper", relationship: "publication")
    IndexSoftwareSearchWorker.drain

    get "/api/v1/projects/search_seeds"
    assert_response :success
    seeds = response.parsed_body.find { |item| item["project_id"] == first.id }.fetch("seeds")
    rrids = seeds.select { |seed| seed["type"] == "rrid" }
    assert_equal ["SCR_002285", "RRID:SCR_002285"], rrids.pluck("value")
    assert_equal [record.id, duplicate.id], rrids.map { |seed| seed.dig("identifier_evidence", "external_software_record_id") }
    assert_equal ["rrid"], rrids.map { |seed| seed.dig("identifier_evidence", "scheme") }.uniq
    assert_equal [{ "source_field" => "distributions.current" }], rrids.first.dig("identifier_evidence", "evidence")
    assert_equal ["10.1234/software"], seeds.select { |seed| seed["type"] == "doi" }.pluck("normalized_value")

    [" rrid:scr_002285 ", "SCR_002285"].each do |query|
      get "/api/v1/software/lookup", params: { q: query, kind: "rrid" }
      assert_response :success
      assert_equal "SCR_002285", response.parsed_body.fetch("query")
      assert_equal [first.id, second.id], response.parsed_body.fetch("projects").pluck("project_id")
      assert_equal 2, response.parsed_body.fetch("projects").first.fetch("seeds").size
    end
    kinds.each do |scheme, value|
      get "/api/v1/software/lookup", params: { q: value.swapcase, kind: scheme }
      assert_response :success
      assert_equal [first.id], response.parsed_body.fetch("projects").pluck("project_id")
    end
    get "/api/v1/software/lookup", params: { q: "SCR_000000", kind: "rrid" }
    assert_response :bad_request
  end

  test "refreshes registry changes removals and record deletion" do
    first = project("first")
    record = identifier(first, "rrid", "SCR_002285")
    IndexSoftwareSearchWorker.drain
    assert_rrid [first.id]
    record.project_external_software_records.sole.update!(match_status: "ambiguous")
    IndexSoftwareSearchWorker.drain
    assert_rrid []
    record.project_external_software_records.sole.update!(match_status: "matched")
    IndexSoftwareSearchWorker.drain
    assert_rrid [first.id]
    record.update!(status: "missing")
    IndexSoftwareSearchWorker.drain
    assert_rrid []
    record.update!(status: "error")
    IndexSoftwareSearchWorker.drain
    assert_rrid [first.id]
    record.destroy!
    IndexSoftwareSearchWorker.drain
    assert_rrid []
    assert_not first.reload.search_identifiers.key?("rrid")
  end

  test "bulk registry imports refresh added and removed identifier candidates" do
    first = project("first")
    entity = JSON.parse(Rails.root.join("test/fixtures/files/rrid.json").read).first
    entity["item"]["identifier"] = "SCR_002285"
    entity["rrid"]["curie"] = "RRID:SCR_002285"
    entity["distributions"] = { "current" => [{ "uri" => first.url }], "alternate" => [] }
    importer = RridImporter.new
    importer.sync_page([entity])
    IndexSoftwareSearchWorker.drain
    assert_rrid [first.id]
    entity["distributions"]["current"] = []
    importer.sync_page([entity], started_at: 1.minute.from_now)
    IndexSoftwareSearchWorker.drain
    assert_rrid []
    assert_not first.reload.search_identifiers.key?("rrid")
  end

  def project(name)
    Project.create!(url: "https://github.com/identifier-seeds/#{name}", name: name, science_score: 50)
  end

  def identifier(project, scheme, value, status: "ok", retrieved_at: Time.current, match_status: "matched", relationship: "source_code_repository")
    record = ExternalSoftwareRecord.create!(source: scheme, identifier: value, status: status,
      retrieved_at: retrieved_at, next_refresh_at: 1.day.from_now)
    project.project_external_software_records.create!(external_software_record: record,
      relationship: relationship, match_status: match_status, evidence: [{ "source_field" => "distributions.current" }])
    record
  end

  def assert_rrid(ids)
    get "/api/v1/software/lookup", params: { q: "SCR_002285", kind: "rrid" }
    assert_response :success
    assert_equal ids, response.parsed_body.fetch("projects").pluck("project_id")
  end
end
