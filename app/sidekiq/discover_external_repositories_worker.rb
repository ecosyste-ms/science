class DiscoverExternalRepositoriesWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3, lock: :until_executed, lock_ttl: 1.hour.to_i,
    lock_prefix: "science:#{Rails.env}:repository-discovery"

  def perform(limit = 100)
    result = ExternalRepositoryDiscovery.new.run(limit: limit)
    ExternalProjectSync.enqueue_pending(limit: limit)
    Rails.logger.info(result.merge(event: "external_repository_discovery").to_json)
    result
  end
end
