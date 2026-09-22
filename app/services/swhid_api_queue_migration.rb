require "sidekiq/api"

class SwhidApiQueueMigration
  WORKERS = %w[CheckSwhidBatchWorker CheckSwhidOriginWorker CheckSwhidArchivalWorker].freeze

  MOVE_QUEUED = <<~LUA
    if redis.call('LREM', KEYS[1], 1, ARGV[1]) == 0 then return 0 end
    redis.call('LPUSH', KEYS[2], ARGV[2])
    redis.call('SADD', 'queues', ARGV[3])
    return 1
  LUA

  MOVE_SCHEDULED = <<~LUA
    local score = redis.call('ZSCORE', KEYS[1], ARGV[1])
    if not score then return 0 end
    redis.call('ZREM', KEYS[1], ARGV[1])
    redis.call('ZADD', KEYS[1], score, ARGV[2])
    return 1
  LUA

  def initialize(source: "swhid", destination: "swh_api", scheduled: "schedule", retries: "retry")
    @source = source
    @destination = destination
    @scheduled = scheduled
    @retries = retries
  end

  def move(dry_run: true)
    ensure_workers_stopped! unless dry_run
    counts = { queued: 0, scheduled: 0, retries: 0, lock_conflicts: 0 }
    jobs = Sidekiq::Queue.new(@source).select { |job| eligible?(job) }
    jobs.reverse_each do |job|
      result = dry_run ? 1 : move_job(job) do |payload|
        Sidekiq.redis { |redis|
          redis.call("EVAL", MOVE_QUEUED, 2, "queue:#{@source}", "queue:#{@destination}",
            job.value, payload, @destination)
        }
      end
      result == :conflict ? counts[:lock_conflicts] += 1 : counts[:queued] += result
    end

    { scheduled: @scheduled, retries: @retries }.each do |type, key|
      Sidekiq::JobSet.new(key).scan("CheckSwhid").each do |job|
        next unless eligible?(job)

        result = dry_run ? 1 : move_job(job) do |payload|
          Sidekiq.redis { |redis| redis.call("EVAL", MOVE_SCHEDULED, 1, key, job.value, payload) }
        end
        result == :conflict ? counts[:lock_conflicts] += 1 : counts[type] += result
      end
    end
    { dry_run: dry_run, source: @source, destination: @destination, **counts }
  end

  def eligible?(job)
    job.item["queue"] == @source && WORKERS.include?(job.klass)
  end

  def ensure_workers_stopped!
    active = Sidekiq::ProcessSet.new.any? do |process|
      (Array(process["queues"]) & [@source, @destination]).any?
    end
    raise "Stop workers consuming #{@source} or #{@destination} before moving API jobs" if active
  end

  def move_job(job)
    item = job.item.merge("queue" => @destination)
    if item["lock_digest"]
      SidekiqUniqueJobs::Job.prepare(item)
      destination_lock = SidekiqUniqueJobs::Locksmith.new(item)
      return :conflict unless destination_lock.lock
    end

    moved = yield Sidekiq.dump_json(item)
    if moved.positive? && destination_lock
      SidekiqUniqueJobs::Locksmith.new(job.item).unlock
    end
    moved
  ensure
    destination_lock.unlock if destination_lock && moved == 0
  end
end
