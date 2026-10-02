class BiotoolsClient
  API_URL = "https://bio.tools/api/tool/"
  COOLDOWN_KEY = "biotools-retry-at"
  PAGE_SIZE = 50

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("bio.tools rate limit or service unavailable")
    end
  end

  def self.identifier(value)
    unless value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_.~-]{1,100}\z/) && !%w[. ..].include?(value)
      raise ArgumentError, "invalid bio.tools identifier"
    end
    value.downcase
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 50 bio.tools identifiers" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def page(number:, limit: PAGE_SIZE)
    raise ArgumentError, "page must be positive" unless number.is_a?(Integer) && number.positive?
    raise ArgumentError, "limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    data = request(API_URL, { format: "json", page: number, per_page: limit, sort: "additionDate", ord: "asc" })
    records = data["list"]
    unless data["count"].is_a?(Integer) && data["count"] >= 0 && data.key?("next") &&
        records.is_a?(Array) && records.size <= limit && records.all? { |record| valid_record?(record) }
      raise Error, "Invalid bio.tools page"
    end
    ids = records.map { |record| self.class.identifier(record["biotoolsID"]) }
    raise Error, "Duplicate bio.tools page identifiers" unless ids.uniq.size == ids.size
    next_page = nil
    if data["next"].present?
      match = data["next"].is_a?(String) && data["next"].match(/\A\?page=([1-9][0-9]*)\z/)
      raise Error, "Invalid bio.tools next page" unless match && match[1].to_i == number + 1 && records.any?
      next_page = match[1].to_i
    end
    { records: records, next_page: next_page }
  end

  def record(id)
    id = self.class.identifier(id)
    data = request("#{API_URL}#{id}/", { format: "json" }, allow_missing: true)
    return { "biotoolsID" => id, "missing" => true } unless data
    unless valid_record?(data) && self.class.identifier(data["biotoolsID"]) == id
      raise Error, "Incomplete or invalid bio.tools record"
    end
    data
  end

  def valid_record?(data)
    data.is_a?(Hash) && self.class.identifier(data["biotoolsID"]) && data["name"].is_a?(String) &&
      data["link"].is_a?(Array) && data["link"].all? { |link| link.is_a?(Hash) && link["type"].is_a?(Array) && link["url"].is_a?(String) }
  rescue ArgumentError
    false
  end

  def request(url, params, allow_missing: false)
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    response = Faraday.get(url, params, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)", "Accept" => "application/json" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    return nil if allow_missing && response.status == 404
    raise Error, "bio.tools HTTP #{response.status}" unless response.success?
    data = JSON.parse(response.body)
    raise Error, "Invalid bio.tools response" unless data.is_a?(Hash)
    data
  rescue Faraday::Error, JSON::ParserError => error
    raise Error, "bio.tools request failed: #{error.class.name}"
  end

  def rate_limited!(value)
    delay = value.to_s.strip
    retry_at = if delay.match?(/\A[0-9]+\z/)
      Time.current + delay.to_i
    else
      Time.httpdate(delay) rescue 5.minutes.from_now
    end
    previous = Rails.cache.read(COOLDOWN_KEY)
    retry_at = [retry_at, 1.minute.from_now, Time.at(previous || 0).utc].max
    Rails.cache.write(COOLDOWN_KEY, retry_at.to_f, expires_in: (retry_at - Time.current).ceil + 60)
    raise RateLimited, retry_at
  end
end
