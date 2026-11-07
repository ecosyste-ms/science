class Jev::SchedulerWorker
  include Sidekiq::Worker
  sidekiq_options queue: "jev", retry: 2, lock: :until_executed, lock_ttl: 5.minutes.to_i,
    lock_prefix: "science:#{Rails.env}:jev-scheduler"

  def perform
    Jev::Scheduler.new.run
  end
end
