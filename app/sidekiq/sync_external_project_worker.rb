class SyncExternalProjectWorker
  include Sidekiq::Worker

  sidekiq_options retry: 3, lock: :until_executing, lock_ttl: 1.hour.to_i,
    lock_prefix: "science:#{Rails.env}:external-project-sync"

  def perform(id)
    request = ExternalProjectSync.find_by(id: id)
    claim = request&.claim
    return unless claim
    token, requested = claim
    SyncProjectWorker.new.perform(request.project_id)
    ExternalProjectSync.find_by(id: id)&.finish(token, requested)
  rescue StandardError => error
    request&.finish(token, requested, error: "#{error.class}: #{error.message}".truncate(1000)) if token
    raise
  end
end
