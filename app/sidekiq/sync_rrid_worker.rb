class SyncRridWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:rrid"

  sidekiq_retry_in { 1.hour.to_i + rand(1..60) }

  def perform(ids)
    RridImporter.new.sync(ids)
  rescue RridClient::RateLimited => error
    self.class.perform_at(error.retry_at + rand(1..60).seconds, ids)
  end
end
