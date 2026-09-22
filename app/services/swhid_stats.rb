class SwhidStats
  KEY = "science:#{Rails.env}:swhid-stats"

  def self.read
    json = Sidekiq.redis { |redis| redis.call("GET", KEY) }
    JSON.parse(json) if json
  end

  def self.refresh
    stats = SwhidCoverageReport.counts.merge(
      "contributions" => SwhidArchiver.contribution_counts,
      "updated_at" => Time.current.iso8601
    )
    saved = Sidekiq.redis { |redis| redis.call("SET", KEY, JSON.generate(stats)) }
    raise "Failed to store SWHID stats" unless saved == "OK"

    stats
  end
end
