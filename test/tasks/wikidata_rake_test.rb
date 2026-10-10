require "test_helper"
require "rake"
require "shellwords"
require_relative "../support/wikidata_pipeline"

class WikidataRakeTest < ActiveSupport::TestCase
  include WikidataPipeline
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("wikidata:import")
    %w[wikidata:import wikidata:refresh wikidata:resume].each { |name| Rake::Task[name].reenable }
    @env = ENV.to_h.slice("IDS", "AFTER", "LIMIT")
    %w[IDS AFTER LIMIT].each { |key| ENV.delete(key) }
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    SyncWikidataWorker.clear
  end

  teardown do
    %w[IDS AFTER LIMIT].each { |key| ENV.delete(key) }
    ENV.update(@env)
  end

  test "bounded source enumeration returns a cursor and queues batches of at most fifty" do
    ENV["AFTER"] = "Q100"
    ids = (101..200).map { |id| "Q#{id}" }
    stub_request(:get, /query\.wikidata\.org\/sparql/).with do |request|
      query = URI.decode_www_form(request.uri.query).to_h.fetch("query")
      query.include?('FILTER(STR(?item) > "http://www.wikidata.org/entity/Q100")') &&
        query.include?("p:P1324/ps:P1324") && query.end_with?("ORDER BY STR(?item) LIMIT 100") && !query.include?("OFFSET")
    end.to_return(body: { results: { bindings: ids.map { |id| { item: { type: "uri", value: "http://www.wikidata.org/entity/#{id}" } } } } }.to_json)
    output, = capture_io { Rake::Task["wikidata:import"].invoke }
    assert_equal({ "queued" => 100, "after" => "Q200", "complete" => false }, JSON.parse(output))
    assert_equal [ids.first(50), ids.last(50)], SyncWikidataWorker.jobs.map { |job| job["args"].sole }
  end

  test "explicit IDs use the same worker without source enumeration" do
    ENV["IDS"] = "Q5971368,Q197520"
    output, = capture_io { Rake::Task["wikidata:import"].invoke }
    assert_equal 2, JSON.parse(output)["queued"]
    assert_equal [[%w[Q5971368 Q197520]]], SyncWikidataWorker.jobs.pluck("args")
    assert_not_requested :any, /wikidata.org/
  end

  test "refresh selects a bounded due population across success missing and error states" do
    ENV["LIMIT"] = "2"
    %w[ok missing error pending].each_with_index do |status, index|
      ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q#{index + 1}", status: status,
        next_refresh_at: index.days.ago)
    end
    ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q5", next_refresh_at: 1.day.from_now)
    ExternalSoftwareRecord.create!(source: "other", identifier: "Q6", next_refresh_at: 1.year.ago)
    output, = capture_io { Rake::Task["wikidata:refresh"].invoke }
    assert_equal 2, JSON.parse(output)["queued"]
    assert_equal [[%w[Q4 Q3]]], SyncWikidataWorker.jobs.pluck("args")
  end

  test "scheduled tasks refresh due records without restarting a completed sweep" do
    import = ExternalSoftwareImport.start_wikidata
    import.update!(completed_at: 1.day.ago, cursor: "Q999", items_processed: 10, pages_processed: 1)
    before = import.attributes
    due = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q197520", next_refresh_at: 1.day.ago)
    future = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q5971368", next_refresh_at: 1.day.from_now)
    entity = JSON.parse(Rails.root.join("test/fixtures/files/wikidata.json").read).fetch("entities").fetch(due.identifier)
    request = stub_request(:get, WikidataClient::API_URL)
      .with(query: { action: "wbgetentities", ids: due.identifier, format: "json", maxlag: 5 })
      .to_return(body: { entities: { due.identifier => entity } }.to_json)
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .select { |entry| entry.fetch("command").include?("wikidata:refresh") }.sole
    assert_equal "*/10 * * * *", cron.fetch("schedule")

    output, = capture_io do
      Shellwords.split(cron.fetch("command")).drop(3).each { |name| Rake::Task[name].invoke }
    end

    assert_equal [{ "queued" => false }, { "queued" => 1 }], output.lines.map { |line| JSON.parse(line) }
    assert_equal [[[due.identifier]]], SyncWikidataWorker.jobs.pluck("args")
    SyncWikidataWorker.perform_one
    assert_equal "ok", due.reload.status
    assert_equal entity, due.metadata
    assert_in_delta 30.days.from_now.to_f, due.next_refresh_at.to_f, 5
    assert_nil future.reload.retrieved_at
    assert_equal before, import.reload.attributes
    assert_empty ImportWikidataWorker.jobs
    assert_requested request, times: 1
    assert_not_requested :get, /query\.wikidata\.org/
  end

  test "bad cursors and unbounded requests never enqueue" do
    ENV["AFTER"] = 'Q1") }'
    assert_raises(ArgumentError) { Rake::Task["wikidata:import"].invoke }
    ENV.delete("AFTER")
    ENV["LIMIT"] = "101"
    Rake::Task["wikidata:import"].reenable
    assert_raises(ArgumentError) { Rake::Task["wikidata:import"].invoke }
    ENV["LIMIT"] = "1001"
    assert_raises(ArgumentError) { Rake::Task["wikidata:refresh"].invoke }
    assert_empty SyncWikidataWorker.jobs
  end
end
