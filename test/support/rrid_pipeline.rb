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
end
