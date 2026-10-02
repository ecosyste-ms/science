class RridClient
  RESOLVER_URL = "https://scicrunch.org/resolver"
  COOLDOWN_KEY = "rrid-retry-at"
  PAGE_SIZE = 50
  SOFTWARE_TYPES = ["software resource", "software application", "software toolkit", "software tool", "source code"].freeze

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("RRID rate limit or service unavailable")
    end
  end

  def self.identifier(value)
    match = value.is_a?(String) && value.match(/\A(?:RRID:)?(SCR_[0-9]{6})\z/i)
    raise ArgumentError, "invalid software RRID" unless match && match[1].upcase != "SCR_000000"
    match[1].upcase
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 50 RRIDs" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def record(id)
    id = self.class.identifier(id)
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    requested_id = id
    redirected_ids = []
    3.times do
      url = "#{RESOLVER_URL}/#{id}.json"
      response = Faraday.get(url, nil,
        { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)", "Accept" => "application/json" }) do |request|
        request.options.open_timeout = 5
        request.options.timeout = 60
      end
      rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
      if [301, 302, 307, 308].include?(response.status)
        target = URI.join(url, response.headers["location"].to_s)
        match = target.path.match(%r{\A/resolver/(SCR_[0-9]{6})\.json\z}i)
        unless target.scheme == "https" && target.host == "scicrunch.org" && target.port == 443 &&
            target.userinfo.nil? && target.query.nil? && target.fragment.nil? && match && match[1].upcase != "SCR_000000"
          raise Error, "Invalid RRID redirect for #{requested_id}"
        end
        redirected_ids << id
        id = self.class.identifier(match[1])
        raise Error, "RRID redirect loop for #{requested_id}" if redirected_ids.include?(id)
        next
      end
      record = response_record(response, id)
      unless redirected_ids.empty?
        aliases = Array(record.dig("item", "alternateIdentifiers")).filter_map do |entry|
          self.class.identifier(entry["identifier"]) if entry.is_a?(Hash)
        rescue ArgumentError
          nil
        end
        unless !record.key?("missing") && (redirected_ids - aliases).empty?
          raise Error, "Unverified RRID redirect from #{requested_id} to #{id}"
        end
      end
      return record
    end
    raise Error, "Too many RRID redirects for #{requested_id}"
  rescue Faraday::Error, JSON::ParserError, URI::InvalidURIError => error
    raise Error, "RRID request failed for #{requested_id}: #{error.class.name}"
  end

  def response_record(response, id)
    raise Error, "RRID HTTP #{response.status} for #{id}" unless [200, 404].include?(response.status)
    raise Error, "RRID response exceeds 5 MB for #{id}" if response.body.bytesize > 5.megabytes
    data = JSON.parse(response.body)
    hits = data.is_a?(Hash) && data["hits"]
    unless hits.is_a?(Hash) && hits["total"].is_a?(Integer) && hits["hits"].is_a?(Array)
      raise Error, "Invalid RRID response for #{id}"
    end
    if response.status == 404 && hits["total"] == 0 && hits["hits"].empty? && data["resolver"].is_a?(Hash) && data["resolver"]["error"] == "RRID not found"
      return { "item" => { "identifier" => id }, "missing" => true }
    end
    unless response.status == 200 && hits["total"].positive? && hits["total"] == hits["hits"].size &&
        hits["hits"].all? { |hit| hit.is_a?(Hash) && hit["_source"].is_a?(Hash) }
      raise Error, "Incomplete RRID result set for #{id}"
    end
    exact = hits["hits"].filter_map do |hit|
      record = hit["_source"]
      record if record["item"].is_a?(Hash) && self.class.identifier(record["item"]["identifier"]) == id
    rescue ArgumentError
      nil
    end
    raise Error, "Expected one exact RRID record for #{id}, got #{exact.size}" unless exact.one?
    raise Error, "Incomplete RRID record for #{id}" unless valid_record?(exact.sole, id)
    exact.sole
  end

  def valid_record?(record, id)
    return false unless record.is_a?(Hash) && record["item"].is_a?(Hash) && record["rrid"].is_a?(Hash)
    item = record["item"]
    return false unless self.class.identifier(item["identifier"]) == id && self.class.identifier(record["rrid"]["curie"]) == id
    return false unless item["name"].is_a?(String) && item["types"].is_a?(Array) &&
      item["types"].all? { |type| type.is_a?(Hash) && type["name"].is_a?(String) }
    return false unless [true, false].include?(record["recordValid"]) && [true, false, "true", "false"].include?(record["rrid"]["is_unique"])
    distributions = record["distributions"]
    distributions.is_a?(Hash) && %w[current alternate].all? do |kind|
      distributions[kind].is_a?(Array) && distributions[kind].all? { |entry| entry.is_a?(Hash) && entry["uri"].is_a?(String) }
    end
  rescue ArgumentError
    false
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
