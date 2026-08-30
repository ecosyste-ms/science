class PackagesApiClient
  BASE_URL = "https://packages.ecosyste.ms/api/v1/"
  MAX_REGISTRIES = 1_000
  RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

  class RequestError < StandardError; end

  attr_reader :connection

  def initialize(connection: nil)
    @connection = connection || build_connection
  end

  def registries(limit: MAX_REGISTRIES)
    raise ArgumentError, "limit must be between 1 and #{MAX_REGISTRIES}" unless limit.to_i.between?(1, MAX_REGISTRIES)
    limit = limit.to_i

    response = connection.get("registries", per_page: limit)
    unless response.success?
      raise RequestError,
        "packages.ecosyste.ms request failed with HTTP #{response.status}"
    end

    records = JSON.parse(response.body)
    unless records.is_a?(Array)
      raise RequestError, "packages.ecosyste.ms returned unexpected JSON"
    end
    total_count = response.headers["total-count"].to_i
    if total_count > limit || (total_count.zero? && records.length >= limit)
      raise RequestError, "packages.ecosyste.ms has more than #{limit} registries"
    end
    if total_count.positive? && records.length != total_count
      raise RequestError, "packages.ecosyste.ms returned an incomplete registry list"
    end
    records
  rescue JSON::ParserError
    raise RequestError, "packages.ecosyste.ms returned invalid JSON"
  rescue Faraday::Error => error
    raise RequestError, "packages.ecosyste.ms request failed: #{error.class}"
  end

  def package_lookup(purl: nil, registry_name: nil, ecosystem: nil, name: nil)
    if purl.present?
      path = "packages/lookup"
      params = { purl: purl }
    elsif registry_name.present? && name.present?
      path = "registries/#{ERB::Util.url_encode(registry_name)}/lookup"
      params = { name: name, ecosystem: ecosystem }.compact
    else
      raise ArgumentError, "purl or registry name and package name are required"
    end

    response = connection.get(path, params)
    unless response.success?
      raise RequestError,
        "packages.ecosyste.ms request failed with HTTP #{response.status}"
    end

    records = JSON.parse(response.body)
    unless records.is_a?(Array)
      raise RequestError, "packages.ecosyste.ms returned unexpected JSON"
    end
    records
  rescue JSON::ParserError
    raise RequestError, "packages.ecosyste.ms returned invalid JSON"
  rescue Faraday::Error => error
    raise RequestError, "packages.ecosyste.ms request failed: #{error.class}"
  end

  def build_connection
    Faraday.new(url: BASE_URL) do |faraday|
      faraday.options.open_timeout = 5
      faraday.options.timeout = 20
      faraday.headers["User-Agent"] = "science.ecosyste.ms"
      if ENV["ECOSYSTEMS_API_KEY"].present?
        faraday.headers["X-API-Key"] = ENV["ECOSYSTEMS_API_KEY"]
      end
      faraday.request :instrumentation
      faraday.request :retry,
        max: 2,
        interval: 0.5,
        interval_randomness: 0.5,
        backoff_factor: 2,
        retry_statuses: RETRY_STATUSES
      faraday.response :follow_redirects
      faraday.adapter Faraday.default_adapter
    end
  end
end
