module RridPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_rrid_jobs
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @rrid = JSON.parse(Rails.root.join("test/fixtures/files/rrid.json").read).index_by { |record| record.dig("item", "identifier") }
    end
    teardown { clear_rrid_jobs }
  end

  def clear_rrid_jobs
    ImportRridSeedsWorker.clear
    ImportRridWorker.clear
    SyncRridWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncRridWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def rrid_response(record)
    { "hits" => { "total" => 1, "hits" => [{ "_source" => record }] } }
  end

  def rrid_record(id, body: nil, status: 200, headers: {})
    stub_request(:get, "#{RridClient::RESOLVER_URL}/#{id}.json")
      .to_return(status: status, headers: headers, body: (body || rrid_response(@rrid.fetch(id))).to_json)
  end

  def expire_rrid
    clear_rrid_jobs
    ExternalSoftwareRecord.where(source: "rrid").update_all(next_refresh_at: 1.minute.ago)
  end

  def sync_rrid(ids)
    SyncRridWorker.perform_async(ids)
    SyncRridWorker.perform_one
  end

  def rrid_catalogue_response(records, total: records.size)
    { "timed_out" => false, "_shards" => { "total" => 2, "successful" => 2, "failed" => 0 },
      "hits" => { "total" => total, "hits" => records.map do |record|
        { "_source" => record, "sort" => [record.dig("item", "identifier").downcase] }
      end } }
  end

  def rrid_page(after: nil, ids: [], limit: 2, total: ids.size, body: nil, status: 200, headers: {})
    filters = [{ "terms" => { "item.types.name.aggregate" => RridClient::SOFTWARE_TYPES } }]
    filters << { "range" => { RridCatalogueClient::IDENTIFIER_FIELD => { "gt" => after.downcase } } } if after
    query = { "size" => limit, "sort" => [{ RridCatalogueClient::IDENTIFIER_FIELD => "asc" }], "query" => { "bool" => { "filter" => filters } } }
    stub_request(:post, RridCatalogueClient::API_URL)
      .with(headers: { "apikey" => "rrid-test-key" }, body: query.to_json)
      .to_return(status: status, headers: headers, body: (body || rrid_catalogue_response(ids.map { |id| @rrid.fetch(id) }, total: total)).to_json)
  end
end
