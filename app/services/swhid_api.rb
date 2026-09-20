require "time"

class SwhidApi
  COOLDOWN_KEY = "swh-api-retry-at"
  DEFAULT_RETRY = 1.hour

  class RateLimited < StandardError
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("HTTP 429")
    end
  end

  def self.check_rate_limit!
    timestamp = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(timestamp).utc if timestamp && timestamp > Time.current.to_f
  end

  def self.request(method, url, body: nil, params: {})
    check_rate_limit!
    response = client(url).public_send(method) do |request|
      request.body = body if body
      request.params = params
    end
    if response.status == 429
      retry_at = retry_time(response.headers["retry-after"])
      previous = Rails.cache.read(COOLDOWN_KEY)
      retry_at = [retry_at, Time.at(previous).utc].max if previous
      Rails.cache.write(COOLDOWN_KEY, retry_at.to_f, expires_in: (retry_at - Time.current).ceil + 60)
      raise RateLimited, retry_at
    end
    response
  end

  def self.retry_time(value)
    value = value.to_s.strip
    time = value.match?(/\A\d+\z/) ? Time.current + value.to_i : Time.httpdate(value)
    [time, 1.minute.from_now].max
  rescue ArgumentError
    Time.current + DEFAULT_RETRY
  end

  def self.retry_job_at(error)
    error.retry_at + rand(1..300).seconds
  end

  def self.client(url)
    Faraday.new(url: url) do |connection|
      connection.headers["User-Agent"] = "science.ecosyste.ms (+https://science.ecosyste.ms)"
      connection.headers["Authorization"] = "Bearer #{ENV['SWH_API_TOKEN']}" if ENV["SWH_API_TOKEN"].present?
      connection.headers["Accept"] = "application/json"
      connection.headers["Content-Type"] = "application/json"
      connection.options.open_timeout = 3
      connection.options.timeout = 10
      connection.request :instrumentation
      connection.adapter Faraday.default_adapter
    end
  end
end
