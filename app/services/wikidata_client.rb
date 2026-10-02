class WikidataClient
  API_URL = "https://www.wikidata.org/w/api.php"
  QUERY_URL = "https://query.wikidata.org/sparql"
  COOLDOWN_KEY = "wikidata-retry-at"
  BATCH_SIZE = 50

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("Wikidata rate limit or replication lag")
    end
  end

  def self.validate_ids!(ids)
    unless ids.is_a?(Array) && ids.size.between?(1, BATCH_SIZE) && ids.all? { |id| id.is_a?(String) && id.match?(/\AQ[1-9][0-9]*\z/) }
      raise ArgumentError, "expected 1 to 50 Wikidata QIDs"
    end
  end

  def entities(ids)
    self.class.validate_ids!(ids)
    data = request(API_URL, action: "wbgetentities", ids: ids.join("|"), format: "json", maxlag: 5)
    entities = data["entities"]
    unless entities.is_a?(Hash) && ids.all? { |id| valid_entity?(entities[id], id) }
      raise Error, "Incomplete or invalid Wikidata entity response"
    end
    entities.slice(*ids)
  end

  def valid_entity?(entity, id)
    entity.is_a?(Hash) && entity["id"] == id &&
      (entity.key?("missing") || (entity["type"] == "item" && entity["claims"].is_a?(Hash)))
  end

  def repository_ids(after: nil, limit: 100)
    self.class.validate_ids!([after]) if after
    raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, 100)

    cursor = after ? %(FILTER(STR(?item) > "http://www.wikidata.org/entity/#{after}")) : ""
    query = "SELECT DISTINCT ?item WHERE { ?item p:P1324/ps:P1324 ?repository . #{cursor} } ORDER BY STR(?item) LIMIT #{limit}"
    data = request(QUERY_URL, query: query, format: "json")
    rows = data.dig("results", "bindings")
    raise Error, "Invalid Wikidata query response" unless rows.is_a?(Array) && rows.size <= limit

    rows.map do |row|
      uri = row.dig("item", "value")
      match = uri.is_a?(String) && uri.match(%r{\Ahttp://www.wikidata.org/entity/(Q[1-9][0-9]*)\z})
      raise Error, "Invalid Wikidata item" unless match
      match[1]
    end
  end

  def request(url, params)
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f

    response = Faraday.get(url, params, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)", "Accept" => "application/json" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "Wikidata HTTP #{response.status}" unless response.success?

    data = JSON.parse(response.body)
    raise Error, "Invalid Wikidata response" unless data.is_a?(Hash)
    rate_limited!(response.headers["retry-after"]) if data.dig("error", "code") == "maxlag"
    raise Error, "Wikidata API error: #{data.dig('error', 'code')}" if data["error"]
    data
  rescue Faraday::Error, JSON::ParserError => error
    raise Error, "Wikidata request failed: #{error.class.name}"
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
