require "test_helper"
require_relative "../support/wikidata_pipeline"

class SyncWikidataWorkerTest < ActiveSupport::TestCase
  include WikidataPipeline
  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    SyncWikidataWorker.clear
    @payload = JSON.parse(File.read(Rails.root.join("test/fixtures/files/wikidata.json")))
    @sympy = Project.create!(url: "https://github.com/sympy/sympy", science_score: 42,
      science_score_breakdown: { "score" => 42, "breakdown" => {} })
    @ids = @payload.fetch("entities").keys
  end

  def stub_entities(payload = @payload, status: 200, headers: {})
    stub_request(:get, WikidataClient::API_URL)
      .with(query: { action: "wbgetentities", ids: @ids.join("|"), format: "json", maxlag: 5 })
      .to_return(status: status, body: payload.to_json, headers: headers)
  end

  def run_worker
    SyncWikidataWorker.perform_async(@ids)
    SyncWikidataWorker.perform_one
  end

  def expire_records
    clear_wikidata_jobs
    ExternalSoftwareRecord.update_all(next_refresh_at: 1.minute.ago)
  end

  test "worker stores live-shaped claims and typed matches without changing projects or their scores" do
    numpy = Project.create!(url: "https://github.com/NumPy/NumPy", science_score: 0)
    scipy = Project.create!(url: "https://github.com/scipy/scipy")
    before = Project.order(:id).map(&:attributes)
    request = stub_entities

    assert_difference "ExternalSoftwareRecord.count", 3 do
      assert_difference "ProjectExternalSoftwareRecord.count", 3 do
        run_worker
      end
    end

    [@sympy, numpy, scipy].zip(@ids).each do |project, id|
      record = project.external_software_records.sole
      assert_equal id, record.identifier
      assert_equal "wikidata", record.source
      assert_equal "ok", record.status
      assert_equal @payload.dig("entities", id), record.metadata
      assert record.retrieved_at
      link = project.project_external_software_records.sole
      assert_equal "source_code_repository", link.relationship
      assert_equal "matched", link.match_status
      assert_equal "project.url", link.evidence.first.fetch("match_method")
    end
    assert_equal before, Project.order(:id).map(&:attributes)
    run_worker
    assert_requested request, times: 1
    assert_equal 3, ProjectExternalSoftwareRecord.count
  end

  test "many to many aliases retain all ambiguous candidates and statement provenance" do
    other = Project.create!(url: "https://github.com/other/suite")
    [other, @sympy].each { |project| project.repository_aliases.create!(url: "https://github.com/sympy/sympy") }
    statement = @payload.dig("entities", "Q5971368", "claims", "P1324").first
    statement["mainsnak"]["datavalue"]["value"] = "https://github.com/SymPy/SymPy.git"
    @payload["entities"]["Q197520"]["claims"]["P1324"] = [statement.deep_dup]
    stub_entities
    run_worker

    assert_equal 2, @sympy.external_software_records.count
    assert_equal 2, other.external_software_records.count
    assert_equal ["ambiguous"], ProjectExternalSoftwareRecord.distinct.pluck(:match_status)
    link = @sympy.project_external_software_records.first
    assert_equal %w[project.url repository_alias], link.evidence.pluck("match_method")
    assert link.evidence.all? { |entry| entry["ambiguous"] }
    assert_equal statement, link.external_software_record.metadata.dig("claims", "P1324").first
  end

  test "Wikidata repository statements convert GitHub Pages and retain original statement evidence" do
    pages_url = "https://SymPy.github.io/sympy/latest/index.html"
    statement = @payload["entities"]["Q5971368"]["claims"]["P1324"].first
    statement["mainsnak"]["datavalue"]["value"] = pages_url
    stub_entities
    run_worker
    evidence = @sympy.project_external_software_records.sole.evidence.sole
    assert_equal statement["id"], evidence["statement_id"]
    assert_equal pages_url, evidence["repository_url"]
    assert_equal pages_url, evidence["source_url"]
    assert_equal "github_pages", evidence["url_transformation"]
    assert_equal @sympy.url, evidence["normalized_url"]
    assert_equal 1, @sympy.external_software_records.count
  end

  test "distinct repositories in a software suite are matched without a false ambiguity" do
    other = Project.create!(url: "https://github.com/suite/second")
    entity = @payload["entities"]["Q5971368"]
    statement = entity["claims"]["P1324"].first.deep_dup
    statement["id"] = "Q5971368$second"
    statement["mainsnak"]["datavalue"]["value"] = other.url
    entity["claims"]["P1324"] << statement
    stub_entities
    run_worker
    assert_equal [@sympy.id, other.id].sort, ExternalSoftwareRecord.find_by!(identifier: "Q5971368").projects.pluck(:id).sort
    assert_equal ["matched"], ProjectExternalSoftwareRecord.distinct.pluck(:match_status)
  end

  test "deprecated invalid and non-value repository claims do not establish identity" do
    entity = @payload["entities"]["Q5971368"]
    valid = entity["claims"]["P1324"].first
    valid["rank"] = "deprecated"
    unknown = valid.deep_dup
    unknown["rank"] = "normal"
    unknown["mainsnak"] = { "snaktype" => "somevalue" }
    invalid = valid.deep_dup
    invalid["rank"] = "preferred"
    invalid["mainsnak"]["datavalue"]["value"] = "https://secret@example.com/repo/path"
    entity["claims"]["P1324"] += [unknown, invalid]
    stub_entities
    run_worker
    assert_empty @sympy.project_external_software_records
    assert_equal entity, ExternalSoftwareRecord.find_by!(identifier: "Q5971368").metadata
  end

  test "successful refresh removes withdrawn matches while retaining the source record" do
    stub_entities
    run_worker
    expire_records
    @payload["entities"]["Q5971368"]["claims"].delete("P1324")
    stub_entities
    run_worker
    assert_empty @sympy.project_external_software_records
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: "Q5971368").status
    assert_equal 3, ExternalSoftwareRecord.count
  end

  test "missing records preserve last known evidence with a distinct status" do
    stub_entities
    run_worker
    previous = @sympy.external_software_records.sole
    expire_records
    @payload["entities"]["Q5971368"] = { "id" => "Q5971368", "missing" => "" }
    stub_entities
    run_worker
    record = @sympy.external_software_records.sole
    assert_equal "missing", record.status
    assert_equal previous.metadata, record.metadata
    assert_equal previous.retrieved_at, record.retrieved_at
    assert record.next_refresh_at > 6.days.from_now
  end

  test "incomplete JSON HTTP and network failures preserve prior evidence" do
    stub_entities
    run_worker
    before = @sympy.external_software_records.sole
    metadata = before.metadata.deep_dup
    retrieved_at = before.retrieved_at
    links = @sympy.project_external_software_records.map(&:attributes)
    [ { "entities" => {} }, { "error" => { "code" => "badvalue" } } ].each do |payload|
      expire_records
      stub_entities(payload)
      assert_raises(WikidataClient::Error) { run_worker }
      assert_equal metadata, before.reload.metadata
      assert_equal retrieved_at, before.retrieved_at
      assert_equal links, @sympy.project_external_software_records.map(&:attributes)
      assert_equal "error", before.status
    end
    expire_records
    stub_entities({}, status: 502)
    assert_raises(WikidataClient::Error) { run_worker }
    assert_equal "Wikidata HTTP 502", before.reload.last_error
    expire_records
    stub_request(:get, WikidataClient::API_URL).with(query: hash_including(action: "wbgetentities")).to_timeout
    assert_raises(WikidataClient::Error) { run_worker }
    assert_equal "error", before.reload.status
    assert_equal links, @sympy.project_external_software_records.map(&:attributes)
  end

  test "unchanged source claims do not rewrite project links on refresh" do
    stub_entities
    run_worker
    before = @sympy.project_external_software_records.sole.attributes
    travel 31.days do
      run_worker
      assert_equal before, @sympy.project_external_software_records.sole.attributes
    end
  end

  test "a slower request cannot overwrite a newer observation" do
    stub_entities
    run_worker
    expire_records
    fresh = @payload["entities"]["Q5971368"].merge("lastrevid" => 9_000_000_000)
    stub_request(:get, WikidataClient::API_URL).with(query: hash_including(action: "wbgetentities")).to_return do
      ExternalSoftwareRecord.find_by!(identifier: "Q5971368").update!(
        metadata: fresh, attempted_at: 1.minute.from_now, retrieved_at: 1.minute.from_now)
      { body: @payload.to_json }
    end
    run_worker
    assert_equal fresh, @sympy.external_software_records.sole.metadata
  end

  test "rate limits set a shared cooldown and reschedule without losing evidence" do
    stub_entities
    run_worker
    expire_records
    before = @sympy.external_software_records.sole
    request = stub_entities({}, status: 429, headers: { "Retry-After" => "600" })
    run_worker
    assert_equal 1, SyncWikidataWorker.jobs.size
    assert SyncWikidataWorker.jobs.first.fetch("at") >= 9.minutes.from_now.to_f
    assert_equal "error", before.reload.status
    assert before.retrieved_at
    assert_equal @payload["entities"]["Q5971368"], before.metadata
    assert_raises(WikidataClient::RateLimited) { WikidataClient.new.entities(["Q1"]) }
    assert_requested request, times: 2
  end

  test "HTTP 200 maxlag is a rate limit and malformed JSON is an error" do
    stub_entities({ "error" => { "code" => "maxlag" } })
    run_worker
    assert_equal ["error"], ExternalSoftwareRecord.distinct.pluck(:status)
    assert_equal 1, SyncWikidataWorker.jobs.size
    Rails.cache.clear
    expire_records
    SyncWikidataWorker.clear
    stub_request(:get, WikidataClient::API_URL).with(query: hash_including(action: "wbgetentities")).to_return(body: "<html>failure</html>")
    assert_raises(WikidataClient::Error) { run_worker }
    assert_empty ProjectExternalSoftwareRecord.all
  end

  test "hidden projects are excluded without fetching project metadata or issuing per-project lookups" do
    owner = Owner.create!(host: Host.create!(name: "Wikidata Host"), login: "hidden", hidden: true)
    @sympy.update_columns(owner_id: owner.id)
    stub_entities
    queries = []
    subscriber = ->(*args) { queries << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { run_worker }
    assert_empty @sympy.project_external_software_records
    project_reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('FROM "projects"') }
    assert_equal 1, project_reads.size
    assert_not_includes project_reads.first, '"projects".*'
    assert_not_includes project_reads.first, "repository ->"
  end

  test "successful batches match through two indexed reads without loading full project rows" do
    Project.create!(url: "https://github.com/numpy/numpy")
    Project.create!(url: "https://github.com/scipy/scipy")
    stub_entities
    queries = []
    subscriber = ->(*args) { queries << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { run_worker }
    project_reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('FROM "projects"') }
    alias_reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('FROM "project_repository_aliases"') }
    assert_equal 1, project_reads.size, project_reads.join("\n")
    assert_equal 1, alias_reads.size
    assert_not_includes project_reads.first, '"projects".*'
    assert_equal 3, ProjectExternalSoftwareRecord.count
  end

  test "invalid or oversized batches fail before any request or database write" do
    [[], ["Q1", "invalid"], (1..51).map { |id| "Q#{id}" }].each do |ids|
      assert_raises(ArgumentError) { SyncWikidataWorker.new.perform(ids) }
    end
    assert_empty ExternalSoftwareRecord.all
    assert_not_requested :get, WikidataClient::API_URL
  end
end
