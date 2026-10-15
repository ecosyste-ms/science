class JournalHttpClient
  class Error < StandardError; end
  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("Journal rate limit or service unavailable")
    end
  end

  def request(url, redirects: 2)
    uri = URI.parse(url)
    unless uri.scheme == "https" && uri.host == self.class::HOST && uri.port == 443 && uri.userinfo.nil?
      raise Error, "Unexpected journal request URL"
    end
    cooldown = Rails.cache.read(cooldown_key)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    response = Faraday.get(url, nil, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 15
    end
    if [301, 302, 303, 307, 308].include?(response.status)
      raise Error, "Too many journal redirects" if redirects.zero? || response.headers["location"].blank?
      return request(URI.join(url, response.headers["location"]).to_s, redirects: redirects - 1)
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "Journal HTTP #{response.status}" unless response.success?
    raise Error, "Journal response exceeds 5 MB" if response.body.bytesize > 5.megabytes
    response.body
  rescue Faraday::Error => error
    raise Error, "Journal request failed: #{error.class.name}"
  rescue URI::InvalidURIError
    raise Error, "Invalid journal request URL"
  end

  def cooldown_key
    "journal-retry-at:#{self.class::HOST}"
  end

  def rate_limited!(value)
    delay = value.to_s.strip
    retry_at = delay.match?(/\A[0-9]+\z/) ? Time.current + delay.to_i : (Time.httpdate(delay) rescue 5.minutes.from_now)
    retry_at = [retry_at, 1.minute.from_now, Time.at(Rails.cache.read(cooldown_key) || 0).utc].max
    Rails.cache.write(cooldown_key, retry_at.to_f, expires_in: (retry_at - Time.current).ceil + 60)
    raise RateLimited, retry_at
  end
end
