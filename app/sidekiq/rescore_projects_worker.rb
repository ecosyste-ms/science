class RescoreProjectsWorker
  include Sidekiq::Worker

  BATCH_SIZE = 1_000
  BATCH_SECONDS = 45
  STATE_KEY = "science:#{Rails.env}:score-refresh"
  ADVISORY_LOCK = 7_349_404

  sidekiq_options queue: "default", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:score-refresh-job"

  def perform
    Project.with_connection do |connection|
      locked = connection.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK})") }
      return unless locked

      begin
        refresh(connection)
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK})")
      end
    end
  end

  def refresh(connection)
    after_id = Sidekiq.redis { |redis| redis.call("HGET", STATE_KEY, "after_id") }.to_i
    ids = Project.visible.where("projects.id > ?", after_id).order(:id).limit(BATCH_SIZE).pluck(:id)
    result = { checked: 0, updated: 0, failed: 0, after_id: after_id }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BATCH_SECONDS

    ids.each do |id|
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      begin
        Project.transaction do
          connection.execute("SET LOCAL statement_timeout = '15s'")
          connection.execute("SET LOCAL lock_timeout = '2s'")
          project = Project.visible.lock.find_by(id: id)
          next unless project

          raise ActiveRecord::RecordInvalid, project unless project.update_science_score

          result[:updated] += 1 if project.saved_changes?
        end
      rescue StandardError => error
        result[:failed] += 1
        Rails.logger.error("Score refresh failed for project #{id}: #{error.class}: #{error.message}")
      end
      result[:checked] += 1
      result[:after_id] = id
    end

    result[:after_id] = 0 if ids.empty?
    result[:checked_at] = Time.current.iso8601
    Sidekiq.redis do |redis|
      redis.call("HSET", STATE_KEY, *result.flat_map { |key, value| [key.to_s, value.to_s] })
      redis.call("HSET", STATE_KEY, "completed_at", result[:checked_at]) if ids.empty?
    end
    Rails.logger.info("Score refresh: #{result.inspect}")
    result
  end
end
