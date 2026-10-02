class SwmathClient
  API_URL = "https://api.zbmath.org/v1/software"
  COOLDOWN_KEY = "swmath-retry-at"
  PAGE_SIZE = 50

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("swMATH rate limit or service unavailable")
    end
  end

  def self.identifier(value)
    raise ArgumentError, "invalid swMATH identifier" unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,9}\z/)
    value
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 50 swMATH identifiers" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def page(after: nil, limit: PAGE_SIZE)
    self.class.identifier(after) if after
    raise ArgumentError, "limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    data, code = request("#{API_URL}/_all", start_after: after || "0", results_per_request: limit)
    if code == 404 && missing?(data, "successful access, but no result", 404) && after
      return { records: [], next_cursor: nil }
    end
    records = data["result"]
    status = data["status"]
    unless code == 200 && successful?(data) && records.is_a?(Array) && records.size.between?(1, limit) &&
        records.all? { |record| valid_record?(record) } && status["nr_request_results"] == records.size &&
        status["nr_total_results"].is_a?(Integer) && status["nr_total_results"] >= records.size
      raise Error, "Invalid swMATH page"
    end
    ids = records.pluck("id")
    unless ids == ids.sort.uniq && ids.first > after.to_i && status["last_id"] == ids.last
      raise Error, "Invalid swMATH cursor"
    end
    if records.size < limit && status["nr_total_results"] > records.size
      raise Error, "Truncated swMATH page"
    end
    { records: records, next_cursor: records.size == limit ? ids.last.to_s : nil }
  end

  def record(id)
    id = self.class.identifier(id)
    data, code = request("#{API_URL}/#{id}")
    if code == 200 && missing?(data, "Entry not found! internal code: id does not exist!", 200)
      return { "id" => id.to_i, "missing" => true }
    end
    record = data["result"]
    unless code == 200 && successful?(data) && valid_record?(record) && record["id"].to_s == id &&
        data.dig("status", "nr_request_results") == 1
      raise Error, "Incomplete or invalid swMATH record"
    end
    record
  end

  def valid_record?(record)
    record.is_a?(Hash) && record["id"].is_a?(Integer) && self.class.identifier(record["id"].to_s) &&
      record["name"].is_a?(String) && record["name"].present? && record.key?("source_code") &&
      (record["source_code"].nil? || record["source_code"].is_a?(String))
  rescue ArgumentError
    false
  end

  def successful?(data)
    data.dig("status", "execution_bool") == true && data.dig("status", "internal_code") == "ok" &&
      data.dig("status", "status_code") == 200
  end

  def missing?(data, internal_code, status_code)
    data.key?("result") && data["result"].nil? && data.dig("status", "execution_bool") == false &&
      data.dig("status", "internal_code") == internal_code && data.dig("status", "status_code") == status_code
  end

  def request(url, params = {})
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    response = Faraday.get(url, params, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)", "Accept" => "application/json" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "swMATH HTTP #{response.status}" unless [200, 404].include?(response.status)
    raise Error, "swMATH response exceeds 20 MB" if response.body.bytesize > 20.megabytes
    data = JSON.parse(response.body)
    raise Error, "Invalid swMATH response" unless data.is_a?(Hash) && data["status"].is_a?(Hash)
    [data, response.status]
  rescue Faraday::Error, JSON::ParserError => error
    raise Error, "swMATH request failed: #{error.class.name}"
  end

  def rate_limited!(value)
    delay = value.to_s.strip
    retry_at = delay.match?(/\A[0-9]+\z/) ? Time.current + delay.to_i : (Time.httpdate(delay) rescue 5.minutes.from_now)
    previous = Rails.cache.read(COOLDOWN_KEY)
    retry_at = [retry_at, 1.minute.from_now, Time.at(previous || 0).utc].max
    Rails.cache.write(COOLDOWN_KEY, retry_at.to_f, expires_in: (retry_at - Time.current).ceil + 60)
    raise RateLimited, retry_at
  end
end
