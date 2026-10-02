class SyncWikidataWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:wikidata"

  sidekiq_retry_in do |_count, error|
    1.hour.to_i + rand(1..60) if error.is_a?(WikidataClient::Error)
  end

  def perform(ids)
    WikidataImporter.new.sync(ids)
  rescue WikidataClient::RateLimited => error
    self.class.perform_at(error.retry_at + rand(1..60).seconds, ids)
  end
end
