module MlossPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_mloss_jobs
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @mloss_html = Rails.root.join("test/fixtures/files/mloss.html").read
    end
    teardown { clear_mloss_jobs }
  end

  def clear_mloss_jobs
    [ImportMlossWorker, SyncMlossWorker, SyncExternalProjectWorker].each do |worker|
      worker.clear
      prefix = worker.get_sidekiq_options["lock_prefix"]
      SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{prefix}:*") if prefix
    end
  end

  def mloss_catalogue(body: @mloss_html, status: 200, headers: {})
    stub_request(:get, MlossClient::CATALOGUE_URL).to_return(status: status, headers: headers, body: body)
  end

  def expire_mloss
    clear_mloss_jobs
    Rails.cache.delete(MlossClient::CACHE_KEY)
    ExternalSoftwareRecord.where(source: "mloss").update_all(next_refresh_at: 1.minute.ago)
  end
end
