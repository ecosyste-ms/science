require "test_helper"
require "rake"
require_relative "../support/wikidata_pipeline"

class ImportWikidataWorkerTest < ActiveSupport::TestCase
  include WikidataPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("wikidata:sweep")
    @env = ENV.to_h.slice("AFTER", "LIMIT", "RESTART")
    %w[AFTER LIMIT RESTART].each { |key| ENV.delete(key) }
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @entities = JSON.parse(File.read(Rails.root.join("test/fixtures/files/wikidata.json"))).fetch("entities")
  end

  teardown do
    %w[AFTER LIMIT RESTART].each { |key| ENV.delete(key) }
    ENV.update(@env)
  end

  def task(name)
    Rake::Task["wikidata:#{name}"].reenable
    output, = capture_io { Rake::Task["wikidata:#{name}"].invoke }
    JSON.parse(output)
  end

  def start_sweep(page_size: 2, after: nil)
    ENV["LIMIT"] = page_size.to_s
    ENV["AFTER"] = after if after
    task("sweep")
    ENV.delete("LIMIT")
    ENV.delete("AFTER")
    ExternalSoftwareImport.find_by!(source: "wikidata")
  end

  def page(ids, after: nil, limit: 2, status: 200, headers: {})
    cursor = after ? %(FILTER(STR(?item) > "http://www.wikidata.org/entity/#{after}")) : ""
    query = "SELECT DISTINCT ?item WHERE { ?item p:P1324/ps:P1324 ?repository . #{cursor} } ORDER BY STR(?item) LIMIT #{limit}"
    stub_request(:get, WikidataClient::QUERY_URL).with(query: { query: query, format: "json" })
      .to_return(status: status, headers: headers, body: { results: { bindings: ids.map { |id| { item: { type: "uri", value: "http://www.wikidata.org/entity/#{id}" } } } } }.to_json)
  end

  def entities(ids, status: 200)
    records = ids.to_h { |id| [id, @entities[id] || { "id" => id, "type" => "item", "claims" => {} }] }
    stub_request(:get, WikidataClient::API_URL)
      .with(query: { action: "wbgetentities", ids: ids.join("|"), format: "json", maxlag: 5 })
      .to_return(status: status, body: { entities: records }.to_json)
  end

  def perform_next
    job = ImportWikidataWorker.jobs.first
    assert job, "expected a continuation job"
    travel_to(Time.at([job["at"] || Time.current.to_f, Time.current.to_f].max) + 1.second) do
      ImportWikidataWorker.perform_one
    end
  end

  test "task runs successive bounded pages through to persisted evidence and completion" do
    projects = %w[scipy numpy sympy].map { |name| Project.create!(url: "https://github.com/#{name}/#{name}", science_score: 42) }
    snapshots = projects.map(&:attributes)
    first = page(%w[Q197492 Q197520], after: "Q100")
    last = page(%w[Q5971368], after: "Q197520")
    entities(%w[Q197492 Q197520])
    entities(%w[Q5971368])
    import = start_sweep(after: "Q100")

    perform_next
    assert_equal "Q197520", import.reload.cursor
    assert_equal 2, import.items_processed
    assert_equal 1, import.pages_processed
    assert_nil import.completed_at
    assert_equal 1, ImportWikidataWorker.jobs.size
    assert_empty SyncWikidataWorker.jobs
    perform_next

    assert import.reload.completed_at
    assert_equal "Q5971368", import.cursor
    assert_equal 3, import.items_processed
    assert_equal 2, import.pages_processed
    assert_empty import.pending_ids
    assert_empty ImportWikidataWorker.jobs
    assert_equal 3, ProjectExternalSoftwareRecord.count
    assert_equal snapshots, projects.map { |project| project.reload.attributes }
    assert_requested first, times: 1
    assert_requested last, times: 1
    assert_equal true, task("status")["complete"]
    task("sweep")
    assert_empty ImportWikidataWorker.jobs
  end

  test "overlapping starts share one cursor and concurrent jobs cannot claim its active lease" do
    import = start_sweep
    task("sweep")
    assert_equal 1, ExternalSoftwareImport.count
    assert_equal 2, ImportWikidataWorker.jobs.size
    request = page(["Q5971368"])
    stub_request(:get, WikidataClient::API_URL).with(query: hash_including(ids: "Q5971368")).to_return do
      ImportWikidataWorker.new.perform(import.id)
      { body: { entities: @entities.slice("Q5971368") }.to_json }
    end
    perform_next
    perform_next
    assert import.reload.completed_at
    assert_equal 1, import.items_processed
    assert_requested request, times: 1
  end

  test "a partial page resumes saved IDs and does not refetch successful batches" do
    ids = (100..150).map { |number| "Q#{number}" }
    query = page(ids, limit: 51)
    successful = entities(ids.first(50))
    entities([ids.last], status: 502)
    import = start_sweep(page_size: 51)
    perform_next
    assert_nil import.reload.cursor
    assert_equal ids, import.pending_ids
    assert_equal 0, import.items_processed
    assert_equal "Wikidata HTTP 502", import.last_error
    assert_equal 50, ExternalSoftwareRecord.where(status: "ok").count
    entities([ids.last])
    perform_next
    assert_equal ids.last, import.reload.cursor
    assert_empty import.pending_ids
    assert_equal 51, import.items_processed
    assert_nil import.last_error
    assert_requested query, times: 1
    assert_requested successful, times: 1
  end

  test "size limited entity responses fetch omitted IDs in smaller batches before advancing" do
    ids = %w[Q197492 Q197520 Q5971368]
    page(ids, limit: 4)
    warning = { "result" => { "*" => "This result was truncated because it would otherwise be larger than the limit of 12,582,912 bytes." } }
    initial = stub_request(:get, WikidataClient::API_URL)
      .with(query: { action: "wbgetentities", ids: ids.join("|"), format: "json", maxlag: 5 })
      .to_return(body: { entities: @entities.slice(ids.first), warnings: warning, success: 1 }.to_json)
    omitted = ids.drop(1).map { |id| entities([id]) }
    project = Project.create!(url: "https://github.com/sympy/sympy", science_score: 42)
    before = project.attributes
    import = start_sweep(page_size: 4)

    perform_next

    assert import.reload.completed_at
    assert_equal ids.last, import.cursor
    assert_equal 3, import.items_processed
    assert_nil import.last_error
    assert_equal ids, ExternalSoftwareRecord.order(:identifier).pluck(:identifier)
    assert_equal ["ok"], ExternalSoftwareRecord.distinct.pluck(:status)
    assert_equal "Q5971368", project.external_software_records.sole.identifier
    assert_equal before, project.reload.attributes
    assert_requested initial, times: 1
    omitted.each { |request| assert_requested request, times: 1 }
  end

  test "repeated truncation is bounded and an omitted singleton preserves the saved page" do
    ids = %w[Q197492 Q197520]
    page(ids)
    warning = { result: { "*" => "This result was truncated because it would otherwise be larger than the limit of 12,582,912 bytes." } }
    requests = [ids, [ids.first]].map do |batch|
      stub_request(:get, WikidataClient::API_URL)
        .with(query: { action: "wbgetentities", ids: batch.join("|"), format: "json", maxlag: 5 })
        .to_return(body: { entities: {}, warnings: warning, success: 1 }.to_json)
    end
    import = start_sweep

    perform_next

    assert_nil import.reload.cursor
    assert_nil import.completed_at
    assert_equal ids, import.pending_ids
    assert_equal 0, import.items_processed
    assert_match "Incomplete or invalid Wikidata entity response", import.last_error
    requests.each { |request| assert_requested request, times: 1 }
    assert_equal ["error"], ExternalSoftwareRecord.distinct.pluck(:status)
  end

  test "a truncation warning does not accept malformed returned entities" do
    ids = %w[Q197492 Q197520]
    page(ids)
    request = stub_request(:get, WikidataClient::API_URL)
      .with(query: { action: "wbgetentities", ids: ids.join("|"), format: "json", maxlag: 5 })
      .to_return(body: { entities: { ids.first => { id: ids.first, type: "item" } },
        warnings: { result: { "*" => "This result was truncated" } } }.to_json)
    entities([ids.last])
    import = start_sweep

    perform_next

    assert_nil import.reload.cursor
    assert_equal ids, import.pending_ids
    assert_equal 0, import.items_processed
    assert_match "Incomplete or invalid Wikidata entity response", import.last_error
    assert_equal ["error"], ExternalSoftwareRecord.distinct.pluck(:status)
    assert_requested request, times: 1
  end

  test "cached errors defer progress until the entity has a successful retry" do
    page(["Q5971368"])
    ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q5971368", status: "error",
      next_refresh_at: 1.hour.from_now, last_error: "Wikidata HTTP 502")
    import = start_sweep
    perform_next
    assert_nil import.reload.cursor
    assert_nil import.completed_at
    assert_equal "Source records awaiting retry", import.last_error
    assert_not_requested :get, /www\.wikidata\.org/
    entities(["Q5971368"])
    perform_next
    assert import.reload.completed_at
    assert_equal 1, import.items_processed
  end

  test "query rate limits retain the cursor and wait for the shared retry time" do
    page([], after: "Q100", status: 429, headers: { "Retry-After" => "600" })
    import = start_sweep(after: "Q100")
    perform_next
    assert_equal "Q100", import.reload.cursor
    assert_equal 0, import.pages_processed
    assert import.next_run_at >= 9.minutes.from_now
    assert_nil import.lease_token
    assert_equal false, task("resume")["queued"]
    page([], after: "Q100")
    perform_next
    assert import.reload.completed_at
  end

  test "an interrupted process is recovered after its lease expires without skipping the pending page" do
    query = page(["Q5971368"])
    stub_request(:get, WikidataClient::API_URL).with(query: hash_including(ids: "Q5971368")).to_raise(Interrupt)
    import = start_sweep
    assert_raises(Interrupt) { perform_next }
    assert_equal ["Q5971368"], import.reload.pending_ids
    assert import.lease_token
    assert_equal false, task("resume")["queued"]
    entities(["Q5971368"])
    travel_to(import.lease_expires_at + 1.second) do
      assert_equal true, task("resume")["queued"]
      ImportWikidataWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 1, import.items_processed
    assert_requested query, times: 1
  end

  test "a stale worker cannot advance the replacement worker's lease" do
    import = start_sweep
    page(["Q5971368"])
    replacement = nil
    stub_request(:get, WikidataClient::API_URL).with(query: hash_including(ids: "Q5971368")).to_return do
      replacement = SecureRandom.uuid
      import.reload.update!(lease_token: replacement, lease_expires_at: 10.minutes.from_now)
      { body: { entities: @entities.slice("Q5971368") }.to_json }
    end
    perform_next
    assert_nil import.reload.cursor
    assert_equal 0, import.items_processed
    assert_equal replacement, import.lease_token
    assert_empty ImportWikidataWorker.jobs
    travel_to(import.lease_expires_at + 1.second) do
      task("resume")
      ImportWikidataWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 1, import.items_processed
  end

  test "recovery resumes the committed cursor if continuation scheduling fails" do
    page(%w[Q197492 Q197520])
    entities(%w[Q197492 Q197520])
    import = start_sweep
    ImportWikidataWorker.stubs(:perform_at).raises(RuntimeError, "queue unavailable")
    assert_raises(RuntimeError) { perform_next }
    ImportWikidataWorker.unstub(:perform_at)
    assert_equal "Q197520", import.reload.cursor
    assert_nil import.lease_token
    assert_equal 2, import.items_processed
    page([], after: "Q197520")
    travel_to(import.next_run_at + 1.second) do
      assert_equal true, task("resume")["queued"]
      ImportWikidataWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 2, import.items_processed
  end

  test "out of order duplicate or nonadvancing query results cannot change the saved cursor" do
    import = start_sweep(after: "Q100")
    [%w[Q102 Q101], %w[Q101 Q101], %w[Q100]].each do |ids|
      page(ids, after: "Q100")
      perform_next
      assert_equal "Q100", import.reload.cursor
      assert_equal 0, import.items_processed
      assert_equal "Wikidata page did not advance in cursor order", import.last_error
    end
    assert_empty ExternalSoftwareRecord.all
  end

  test "only an explicit restart resets a completed sweep" do
    import = start_sweep
    ENV["RESTART"] = "true"
    assert_raises(ArgumentError) { task("sweep") }
    ENV.delete("RESTART")
    page([])
    perform_next
    task("sweep")
    assert import.reload.completed_at
    assert_empty ImportWikidataWorker.jobs
    ENV["RESTART"] = "true"
    ENV["AFTER"] = "Q100"
    progress = task("sweep")
    assert_equal false, progress["complete"]
    assert_equal "Q100", progress["after"]
    assert_equal 0, progress["pages_processed"]
    assert_equal 1, ImportWikidataWorker.jobs.size
  end

  test "status and scheduled recovery do not create a sweep or fetch source data" do
    assert_equal({ "status" => "not_started" }, task("status"))
    assert_equal({ "queued" => false }, task("resume"))
    assert_empty ExternalSoftwareImport.all
    assert_empty ImportWikidataWorker.jobs
    assert_not_requested :any, /wikidata.org/
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
    assert_includes cron, { "command" => "bundle exec rake wikidata:resume wikidata:refresh", "schedule" => "*/10 * * * *" }
  end

  test "invalid parameters and attempts to move an active cursor are rejected" do
    ENV["LIMIT"] = "101"
    assert_raises(ArgumentError) { task("sweep") }
    ENV.delete("LIMIT")
    ENV["AFTER"] = "invalid"
    assert_raises(ArgumentError) { task("sweep") }
    ENV.delete("AFTER")
    assert_empty ExternalSoftwareImport.all
    import = start_sweep(after: "Q100")
    ENV["AFTER"] = "Q200"
    assert_raises(ArgumentError) { task("sweep") }
    assert_equal "Q100", import.reload.cursor
  end
end
