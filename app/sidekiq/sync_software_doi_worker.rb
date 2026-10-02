class SyncSoftwareDoiWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:software-doi"

  sidekiq_retry_in { 1.hour.to_i + rand(1..60) }

  def perform(ids)
    SoftwareDoiImporter.new.sync(ids)
  rescue SoftwareDoiClient::RateLimited => error
    self.class.perform_at(error.retry_at + rand(1..60).seconds, ids)
  end
end
