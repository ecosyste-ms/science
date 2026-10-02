module WikidataPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_wikidata_jobs
    end

    teardown { clear_wikidata_jobs }
  end

  def clear_wikidata_jobs
    ImportWikidataWorker.clear
    SyncWikidataWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncWikidataWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end
end
