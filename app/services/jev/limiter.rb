class Jev::Limiter
  class Busy < StandardError; end

  ACQUIRE = <<~LUA.freeze
    redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
    if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[3]) then return 0 end
    if tonumber(ARGV[5]) > 0 and not redis.call('SET', KEYS[2], '1', 'NX', 'PX', ARGV[5]) then return 0 end
    redis.call('ZADD', KEYS[1], ARGV[2], ARGV[4])
    redis.call('EXPIRE', KEYS[1], 900)
    return 1
  LUA

  def self.with_slot(kind)
    concurrency = kind == "api" ? Jev::Settings.integer("CONCURRENCY", 2, 1..16) : Jev::Settings.integer("ENRICH_CONCURRENCY", 1, 1..4)
    interval = kind == "api" ? (1000.0 / Jev::Settings.integer("REQUESTS_PER_SECOND", 5, 1..40)).ceil : 0
    ttl = kind == "api" ? 60 : 600
    key = "science:#{Rails.env}:jev:#{kind}"
    token = SecureRandom.hex(16)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    acquired = nil
    loop do
      now = Time.now.to_f
      acquired = Sidekiq.redis { |redis| redis.call("EVAL", ACQUIRE, 2, key, "#{key}:rate", now, now + ttl, concurrency, token, interval) }
      break if acquired == 1 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    raise Busy, "Jev #{kind} capacity reached" unless acquired == 1
    begin
      yield
    ensure
      Sidekiq.redis { |redis| redis.call("ZREM", key, token) }
    end
  end
end
