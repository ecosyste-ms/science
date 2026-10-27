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
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = Faraday.get(url, nil, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 15
    end
    if [301, 302, 303, 307, 308].include?(response.status)
      raise Error, "Too many journal redirects at #{uri.path}" if redirects.zero? || response.headers["location"].blank?
      return request(URI.join(url, response.headers["location"]).to_s, redirects: redirects - 1)
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "Journal HTTP #{response.status}" unless response.success?
    raise Error, "Journal response exceeds 5 MB" if response.body.bytesize > 5.megabytes
    response.body
  rescue Faraday::Error => error
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)
    cause = error.wrapped_exception || error.cause
    detail = cause ? " (#{cause.class.name})" : ""
    raise Error, "Journal request failed at #{uri.scheme}://#{uri.host}#{uri.path}: #{error.class.name}#{detail}; elapsed=#{elapsed}s, open_timeout=5s, timeout=15s"
  rescue URI::InvalidURIError
    raise Error, "Invalid journal request URL"
  end

  def cooldown_key
    "journal-retry-at:#{self.class::HOST}"
  end

  def repository_url?(url)
    uri = RepositoryUrlNormalizer.parse(url)
    return false unless uri && %w[http https].include?(uri.scheme) && uri.userinfo.nil? && [80, 443].include?(uri.port)
    return false if uri.path.split("/").any? { |part| %w[. ..].include?(part) }
    return false if RepositoryUrlNormalizer.github_pages_repository(url)
    normalized = RepositoryUrlNormalizer.normalize(url)
    @repository_importer ||= ExternalSoftwareImporter.new
    normalized && @repository_importer.repository_url?(normalized)
  end

  def rate_limited!(value)
    delay = value.to_s.strip
    retry_at = delay.match?(/\A[0-9]+\z/) ? Time.current + delay.to_i : (Time.httpdate(delay) rescue 5.minutes.from_now)
    retry_at = [retry_at, 1.minute.from_now, Time.at(Rails.cache.read(cooldown_key) || 0).utc].max
    Rails.cache.write(cooldown_key, retry_at.to_f, expires_in: (retry_at - Time.current).ceil + 60)
    raise RateLimited, retry_at
  end
end
