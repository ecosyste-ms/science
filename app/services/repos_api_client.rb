class ReposApiClient
  BASE_URL = "https://repos.ecosyste.ms/api/v1/"
  PER_PAGE = 100
  RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

  class RequestError < StandardError; end

  attr_reader :connection

  def initialize(connection: nil)
    @connection = connection || build_connection
  end

  def gitlab_hosts
    page = 1
    hosts = []

    loop do
      response = get_hosts(page)
      records = JSON.parse(response.body)
      hosts.concat(
        records.filter_map do |record|
          record["url"] if record["kind"].to_s.casecmp?("gitlab")
        end
      )

      total_pages = response.headers["total-pages"].to_i
      break if total_pages.positive? ? page >= total_pages : records.length < PER_PAGE
      page += 1
    end

    hosts.uniq
  rescue JSON::ParserError
    raise RequestError, "repos.ecosyste.ms returned invalid JSON"
  end

  def get_hosts(page)
    response = connection.get("hosts", per_page: PER_PAGE, page: page)
    unless response.success?
      raise RequestError,
        "repos.ecosyste.ms request failed with HTTP #{response.status}"
    end
    response
  rescue Faraday::Error => error
    raise RequestError, "repos.ecosyste.ms request failed: #{error.class}"
  end

  def build_connection
    Faraday.new(url: BASE_URL) do |faraday|
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
