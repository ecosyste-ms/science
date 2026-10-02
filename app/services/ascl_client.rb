class AsclClient
  CATALOGUE_URL = "https://ascl.net/code/json"
  SEARCH_URL = "https://ascl.net/api/search/"
  CACHE_KEY = "ascl-catalogue-chunks"
  CACHE_CHUNK_BYTES = 256.kilobytes
  COOLDOWN_KEY = "ascl-retry-at"
  PAGE_SIZE = 50
  MAX_RECORDS = 20_000

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("ASCL rate limit or service unavailable")
    end
  end

  def self.identifier(value)
    unless value.is_a?(String) && value.match?(/\A[0-9]{2}(?:0[1-9]|1[0-2])\.[0-9]{3}\z/) && !value.end_with?(".000")
      raise ArgumentError, "invalid ASCL identifier"
    end
    value
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 50 ASCL identifiers" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def catalogue
    cached_catalogue || fetch_catalogue
  end

  def cached_catalogue
    manifest = Rails.cache.read(CACHE_KEY)
    return unless manifest.is_a?(Hash) && manifest["keys"].is_a?(Array) && manifest["keys"].any?
    chunks = Rails.cache.read_multi(*manifest["keys"])
    return unless manifest["keys"].all? { |key| chunks[key].is_a?(String) }
    JSON.parse(manifest["keys"].map { |key| chunks.fetch(key) }.join.force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError
    nil
  end

  def cache_catalogue(snapshot)
    payload = JSON.generate(snapshot).b
    prefix = "#{CACHE_KEY}:#{SecureRandom.uuid}"
    keys = []
    (0...payload.bytesize).step(CACHE_CHUNK_BYTES).each_with_index do |offset, index|
      key = "#{prefix}:#{index}"
      return unless Rails.cache.write(key, payload.byteslice(offset, CACHE_CHUNK_BYTES), expires_in: 6.hours + 1.minute)
      keys << key
    end
    Rails.cache.write(CACHE_KEY, { "keys" => keys }, expires_in: 6.hours)
  end

  def fetch_catalogue
    retrieved_at = Time.current.to_f
    data = request(CATALOGUE_URL)
    unless data.is_a?(Hash) && data.size.between?(1, MAX_RECORDS) && data.values.all? { |record| valid_record?(record) }
      raise Error, "Invalid ASCL catalogue"
    end
    records = data.values.sort_by { |record| record.fetch("ascl_id") }
    ids = records.pluck("ascl_id")
    raise Error, "Duplicate ASCL identifiers" unless ids.uniq.size == ids.size
    index = request(SEARCH_URL, { q: '""', fl: "ascl_id" })
    unless index.is_a?(Array) && index.size.between?(1, MAX_RECORDS) &&
        index.all? { |entry| entry.is_a?(Hash) && entry["ascl_id"].is_a?(String) }
      raise Error, "Invalid ASCL identifier index"
    end
    published = index.pluck("ascl_id").reject { |id| id == "0000.000" }
    unless published.sort == ids
      raise Error, "ASCL catalogue and published identifier index disagree"
    end
    snapshot = { "records" => records, "retrieved_at" => retrieved_at }
    cache_catalogue(snapshot)
    snapshot
  end

  def page(after: nil, limit: PAGE_SIZE)
    self.class.identifier(after) if after
    raise ArgumentError, "limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    snapshot = catalogue
    records = snapshot.fetch("records")
    offset = after ? (records.bsearch_index { |record| record.fetch("ascl_id") > after } || records.size) : 0
    page = records.slice(offset, limit)
    { records: page, next_cursor: offset + page.size < records.size ? page.last.fetch("ascl_id") : nil,
      retrieved_at: Time.at(snapshot.fetch("retrieved_at")).utc }
  end

  def records(ids)
    ids = self.class.validate_ids!(ids)
    snapshot = catalogue
    selected = snapshot.fetch("records").select { |record| ids.include?(record["ascl_id"]) }.index_by { |record| record["ascl_id"] }
    { records: ids.map { |id| selected[id] || { "ascl_id" => id, "missing" => true } },
      retrieved_at: Time.at(snapshot.fetch("retrieved_at")).utc }
  end

  def valid_record?(record)
    record.is_a?(Hash) && self.class.identifier(record["ascl_id"]) && record["title"].is_a?(String) &&
      (record["site_list"] == false || (record["site_list"].is_a?(Array) && record["site_list"].all? { |url| url.is_a?(String) }))
  rescue ArgumentError
    false
  end

  def request(url, params = {})
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    response = Faraday.get(url, params, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)", "Accept" => "application/json" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "ASCL HTTP #{response.status}" unless response.success?
    raise Error, "ASCL response exceeds 20 MB" if response.body.bytesize > 20.megabytes
    JSON.parse(response.body)
  rescue Faraday::Error, JSON::ParserError => error
    raise Error, "ASCL request failed: #{error.class.name}"
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
