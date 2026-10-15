class MlossClient
  CATALOGUE_URL = "https://www.jmlr.org/mloss/"
  CACHE_KEY = "mloss-catalogue"
  COOLDOWN_KEY = "mloss-retry-at"
  PAGE_SIZE = 50

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("MLOSS rate limit or service unavailable")
    end
  end

  def self.identifier(value)
    unless value.is_a?(String) && value.match?(%r{\Av[1-9][0-9]*/[a-zA-Z0-9_-]+\z}) && value.length <= 200
      raise ArgumentError, "invalid MLOSS article identifier"
    end
    value
  end

  def self.article_url(id)
    "https://www.jmlr.org/papers/#{identifier(id)}.html"
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 50 MLOSS identifiers" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def catalogue
    cached = Rails.cache.read(CACHE_KEY)
    return JSON.parse(cached) if cached.is_a?(String)

    retrieved_at = Time.current.to_f
    records = parse_catalogue(request)
    snapshot = { "records" => records, "retrieved_at" => retrieved_at }
    payload = JSON.generate(snapshot)
    Rails.cache.write(CACHE_KEY, payload, expires_in: 6.hours) if payload.bytesize <= 512.kilobytes
    snapshot
  end

  def parse_catalogue(body)
    doc = Nokogiri::HTML(body)
    unless doc.css("h1,h2,h3").any? { |node| node.text.squish == "Machine Learning Open Source Software" }
      raise Error, "Missing MLOSS catalogue heading"
    end
    entries = doc.css("dl")
    raise Error, "Invalid MLOSS catalogue size" unless entries.size.between?(1, 10_000)
    records = entries.map do |entry|
      title = entry.at_css("dt")&.text&.squish
      details = entry.at_css("dd")
      raise Error, "Incomplete MLOSS article" if title.blank? || details.nil?
      links = details.css("a[href]")
      abstracts = links.select { |link| link.text.strip == "abs" }
      code = links.select { |link| link.text.strip == "code" }
      raise Error, "Missing MLOSS article or code link" unless abstracts.one? && code.any?
      article = URI.join(CATALOGUE_URL, abstracts.first["href"])
      match = article.path.match(%r{\A/papers/(v[1-9][0-9]*/[a-zA-Z0-9_-]+)\.html\z})
      unless match && %w[http https].include?(article.scheme) && %w[jmlr.org www.jmlr.org].include?(article.host) &&
          article.userinfo.nil? && [80, 443].include?(article.port) && article.query.nil? && article.fragment.nil?
        raise Error, "Invalid MLOSS article URL"
      end
      id = self.class.identifier(match[1])
      { "id" => id, "article_url" => self.class.article_url(id), "title" => title,
        "bibliographic_details" => details.text.squish,
        "code_urls" => code.map { |link| URI.join(CATALOGUE_URL, link["href"]).to_s }.uniq }
    end
    unless records.pluck("id").uniq.size == records.size &&
        doc.css("a").count { |link| link.text.strip == "abs" } == records.size
      raise Error, "Duplicate or unparsed MLOSS articles"
    end
    records.sort_by { |record| record.fetch("id") }
  rescue URI::InvalidURIError, ArgumentError => error
    raise Error, "Invalid MLOSS catalogue: #{error.class.name}"
  end

  def page(after: nil, limit: PAGE_SIZE)
    self.class.identifier(after) if after
    raise ArgumentError, "limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    snapshot = catalogue
    records = snapshot.fetch("records")
    offset = after ? (records.bsearch_index { |record| record.fetch("id") > after } || records.size) : 0
    page = records.slice(offset, limit)
    { records: page, next_cursor: offset + page.size < records.size ? page.last.fetch("id") : nil,
      retrieved_at: Time.at(snapshot.fetch("retrieved_at")).utc }
  end

  def records(ids)
    ids = self.class.validate_ids!(ids)
    snapshot = catalogue
    selected = snapshot.fetch("records").index_by { |record| record.fetch("id") }.slice(*ids)
    raise Error, "Requested articles absent from MLOSS catalogue" unless selected.size == ids.size
    { records: ids.map { |id| selected.fetch(id) }, retrieved_at: Time.at(snapshot.fetch("retrieved_at")).utc }
  end

  def request
    cooldown = Rails.cache.read(COOLDOWN_KEY)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    response = Faraday.get(CATALOGUE_URL, nil, { "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)", "Accept" => "text/html" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    rate_limited!(response.headers["retry-after"]) if [429, 503].include?(response.status)
    raise Error, "MLOSS HTTP #{response.status}" unless response.success?
    raise Error, "MLOSS response exceeds 5 MB" if response.body.bytesize > 5.megabytes
    response.body
  rescue Faraday::Error => error
    raise Error, "MLOSS request failed: #{error.class.name}"
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
