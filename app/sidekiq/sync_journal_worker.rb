class SyncJournalWorker
  include Sidekiq::Worker
  sidekiq_options queue: "external_metadata", retry: 3

  def perform(source, ids)
    ImportJournalWorker::IMPORTERS.fetch(source).new.sync(ids)
  rescue JournalHttpClient::RateLimited => error
    self.class.perform_at(error.retry_at + rand(1..60).seconds, source, ids)
  end
end
