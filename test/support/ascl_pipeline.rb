module AsclPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_ascl_jobs
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @ascl = JSON.parse(Rails.root.join("test/fixtures/files/ascl.json").read).index_by { |record| record.fetch("ascl_id") }
    end
    teardown { clear_ascl_jobs }
  end

  def clear_ascl_jobs
    ImportAsclWorker.clear
    SyncAsclWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncAsclWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def ascl_catalogue(records = @ascl.values, index: nil, status: 200, headers: {})
    data = records.each_with_index.to_h { |record, i| [(i + 1).to_s, record] }
    request = stub_request(:get, AsclClient::CATALOGUE_URL).to_return(status: status, headers: headers, body: data.to_json)
    index ||= records.map { |record| { "ascl_id" => record.fetch("ascl_id") } } + [{ "ascl_id" => "0000.000" }]
    stub_request(:get, AsclClient::SEARCH_URL).with(query: { q: '""', fl: "ascl_id" }).to_return(body: index.to_json)
    request
  end

  def expire_ascl
    clear_ascl_jobs
    Rails.cache.delete(AsclClient::CACHE_KEY)
    ExternalSoftwareRecord.where(source: "ascl").update_all(next_refresh_at: 1.minute.ago)
  end

  def sync_ascl(ids)
    SyncAsclWorker.perform_async(ids)
    SyncAsclWorker.perform_one
  end
end
