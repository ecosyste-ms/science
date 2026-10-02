require "test_helper"
require "rake"
require_relative "../support/wikidata_pipeline"

class WikidataRakeTest < ActiveSupport::TestCase
  include WikidataPipeline
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("wikidata:import")
    %w[wikidata:import wikidata:refresh].each { |name| Rake::Task[name].reenable }
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
