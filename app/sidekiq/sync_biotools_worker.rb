class SyncBiotoolsWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:biotools"

  sidekiq_retry_in do |_count, error|
    1.hour.to_i + rand(1..60) if error.is_a?(BiotoolsClient::Error)
  end

  def perform(ids)
    BiotoolsImporter.new.sync(ids)
  rescue BiotoolsClient::RateLimited => error
    self.class.perform_at(error.retry_at + rand(1..60).seconds, ids)
  end
end
