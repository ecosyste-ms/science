class EnrichJournalPaperWorker
  include Sidekiq::Worker

  sidekiq_options queue: "external_metadata", retry: 3, lock: :until_executing, lock_ttl: 10.minutes.to_i,
    lock_prefix: "science:#{Rails.env}:journal-paper-enrichment"

  def perform(id)
    return if ENV["OPENALEX_API_KEY"].blank?
    record = JournalPaperEnrichment.find_by(id: id)
    return unless record && record.paper.paper_identifiers.where(source: JournalPaperEnrichment::SOURCES).exists?
    token = record.claim
    return unless token

    work = JournalPaperResolver.new.resolve(record.paper)
    record.finish(token, status: work ? "ok" : "not_found", next_attempt_at: work ? 30.days.from_now : 7.days.from_now, work: work)
  rescue OpenAlexApiClient::RequestError => error
    status = case error.status
    when 404 then "not_found"
    when 429, 503 then "rate_limited"
    when 401, 403 then "unauthorized"
    else "error"
    end
    retry_at = case status
    when "not_found" then 7.days.from_now
    when "unauthorized" then 6.hours.from_now
    else 1.hour.from_now
    end
    retry_at = [error.retry_at, 1.minute.from_now].max if error.retry_at
    record.finish(token, status: status, next_attempt_at: retry_at, error: error.message)
  rescue JournalPaperResolver::IdentityConflict, ArgumentError, ActiveRecord::RecordInvalid => error
    record.finish(token, status: "conflict", next_attempt_at: 7.days.from_now, error: error.message) if token
  rescue StandardError => error
    record.finish(token, status: "error", next_attempt_at: 1.hour.from_now, error: error.class.name) if token
    raise
  end
end
