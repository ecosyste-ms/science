class CheckSwhidHistoryWorker
  include Sidekiq::Worker

  BATCH_SIZE = SwhidArchiveChecker::MAX_IDENTIFIERS / SwhidHistoryChecker::MAX_CHECKS
  LOCK_NAMESPACE = 7_349_403

  sidekiq_options queue: "swhid", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:swhid-history"

  def perform(project_ids)
    raise ArgumentError, "Expected 1..#{BATCH_SIZE} project IDs" unless project_ids.is_a?(Array) && project_ids.size.between?(1, BATCH_SIZE)

    prepared = []
    SwhidHistoryChecker.eligible.where(id: project_ids).find_each do |project|
      Project.with_connection do |connection|
        locked = connection.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{project.id})") }
        next unless locked

        begin
          checker = SwhidHistoryChecker.new(project.reload)
          checker.prepare
          prepared << project.id if checker.pending.any?
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{project.id})")
        end
      end
    end
    CheckSwhidHistoryBatchWorker.perform_async(prepared) if prepared.any?
  end
end
