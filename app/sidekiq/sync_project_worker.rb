class SyncProjectWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options lock: :until_executed, lock_ttl: 1.hour.to_i,
    lock_prefix: "science:#{Rails.env}:project-sync"

  def perform(project_id)
    Project.find_by_id(project_id).try(:sync)
  end
end
