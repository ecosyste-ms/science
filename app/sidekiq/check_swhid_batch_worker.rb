class CheckSwhidBatchWorker
  include Sidekiq::Worker

  BATCH_SIZE = SwhidArchiveChecker::MAX_IDENTIFIERS / 2
  BATCH_DELAY = 30.seconds
  PENDING_KEY = "science:#{Rails.env}:swhid-checks"
  ADVISORY_LOCK = 7_349_401

  sidekiq_options queue: "swhid", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:swhid-batch"

  def self.enqueue(project_id)
    Sidekiq.redis { |redis| redis.call("ZADD", PENDING_KEY, "NX", Time.current.to_f, project_id.to_s) }
    perform_in(BATCH_DELAY)
  end

  def perform
    Project.with_connection do |connection|
      locked = connection.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK})") }
      return unless locked

      begin
        SwhidApi.check_rate_limit!
        ids = Sidekiq.redis { |redis| redis.call("ZRANGE", PENDING_KEY, 0, BATCH_SIZE - 1) }
        check_projects(ids) if ids.any?
      rescue SwhidApi::RateLimited => error
        retry_at = SwhidApi.retry_job_at(error)
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK})")
      end
      pending = Sidekiq.redis { |redis| redis.call("ZCARD", PENDING_KEY) }
      self.class.perform_at(retry_at || BATCH_DELAY.from_now) if pending.positive?
    end
  end

  def check_projects(ids)
    projects = Project.visible.scientific.with_repository.where(id: ids).order(:id).to_a
    snapshots = projects.to_h { |project| [project.id, project.swhids.deep_dup] }
    checkers = projects.to_h { |project| [project.id, SwhidArchiveChecker.new(project.swhids)] }
    SwhidArchiveChecker.check_batch(checkers.values.map { |checker| [checker, checker.due_objects] })

    (ids - projects.map { |project| project.id.to_s }).each { |id| remove(id) }
    projects.each do |project|
      checker = checkers.fetch(project.id)
      persist(project, snapshots.fetch(project.id), checker.data)
      next if checker.rate_limit

      if SwhidArchiveChecker.new(project.swhids).due?
        self.class.enqueue(project.id)
      else
        CheckSwhidArchivalWorker.perform_async(project.id) if SwhidArchiver.new(project).due?
        remove(project.id)
      end
    end
    rate_limit = checkers.values.filter_map(&:rate_limit).first
    raise rate_limit if rate_limit
  end

  def persist(project, snapshot, result)
    project.with_lock do
      data = project.swhids.deep_dup
      next unless data

      %w[revision directory].each do |type|
        # A concurrent scan or confirmation takes precedence over this response.
        next unless data[type] == snapshot&.dig(type)
        next unless result.dig(type, "archive")

        data[type]["archive"] = result[type]["archive"]
      end
      project.update!(swhids: data) if data != project.swhids
    end
  end

  def remove(project_id)
    Sidekiq.redis { |redis| redis.call("ZREM", PENDING_KEY, project_id.to_s) }
  end
end
