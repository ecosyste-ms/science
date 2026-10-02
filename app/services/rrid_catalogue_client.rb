class RridCatalogueClient < RridClient
  API_URL = "https://api.scicrunch.io/elastic/v1/RIN_Tool_pr/_search"
  IDENTIFIER_FIELD = "item.identifier.aggregate"

  def page(after: nil, limit: PAGE_SIZE)
    raise ArgumentError, "limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    after = self.class.identifier(after) if after
    key = ENV["SCICRUNCH_API_KEY"].presence
    raise Error, "SCICRUNCH_API_KEY is not configured" unless key
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    filters = [{ terms: { "item.types.name.aggregate" => SOFTWARE_TYPES } }]
    filters << { range: { IDENTIFIER_FIELD => { gt: after.downcase } } } if after
    query = { size: limit, sort: [{ IDENTIFIER_FIELD => "asc" }], query: { bool: { filter: filters } } }
    response = Faraday.post(API_URL, JSON.generate(query),
      { "apikey" => key, "Content-Type" => "application/json", "Accept" => "application/json",
        "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "SciCrunch catalogue HTTP #{response.status}" unless response.status == 200
    raise Error, "SciCrunch catalogue response exceeds 5 MB" if response.body.bytesize > 5.megabytes
    data = JSON.parse(response.body)
    validate_page(data, after: after, limit: limit)
  rescue Faraday::Error, JSON::ParserError => error
    raise Error, "SciCrunch catalogue request failed: #{error.class.name}"
  end

  def validate_page(data, after:, limit:)
    shards = data["_shards"] if data.is_a?(Hash)
    hits = data["hits"] if data.is_a?(Hash)
    unless data.is_a?(Hash) && data["timed_out"] == false && shards.is_a?(Hash) &&
        shards["total"].is_a?(Integer) && shards["total"].positive? &&
        shards["successful"] == shards["total"] && shards["failed"] == 0 &&
        hits.is_a?(Hash) && hits["total"].is_a?(Integer) && hits["total"] >= 0 && hits["hits"].is_a?(Array) &&
        hits["hits"].size == [hits["total"], limit].min
      raise Error, "Incomplete SciCrunch catalogue page"
    end
    records = hits["hits"].map do |hit|
      record = hit["_source"] if hit.is_a?(Hash)
      id = self.class.identifier(record.dig("item", "identifier")) if record.is_a?(Hash) && record["item"].is_a?(Hash)
      unless id && valid_record?(record, id) && hit["sort"] == [id.downcase] &&
          record["item"]["types"].any? { |type| SOFTWARE_TYPES.include?(type["name"].downcase) }
        raise Error, "Invalid SciCrunch catalogue record"
      end
      record
    end
    ids = records.map { |record| self.class.identifier(record.dig("item", "identifier")) }
    unless ids == ids.sort.uniq && ids.all? { |id| after.nil? || id > after }
      raise Error, "SciCrunch catalogue cursor did not advance"
    end
    { records: records, next_cursor: (ids.last if hits["total"] > ids.size) }
  rescue ArgumentError
    raise Error, "Invalid SciCrunch catalogue identifier"
  end
end
