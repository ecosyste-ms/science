require "uri"

class OpenAlexApiClient
  BASE_URL = "https://api.openalex.org"
  PER_PAGE = 100
  DOIS_PER_REQUEST = 100
  DOI_PATTERN = /\A10\.\d{4,9}\/\S+\z/i
  DOI_IMAGE_URL_PATTERN = %r{
    \Ahttps?://(?:www\.|dx\.)?doi\.org/\S+\.(?:gif|jpe?g|png|svg|webp)(?:[?#]\S*)?\z
  }ix
  DOI_IMAGE_SUFFIX_PATTERN = /\.(?:gif|jpe?g|png|svg|webp)\z/i
  RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

  class RequestError < StandardError; end

  attr_reader :api_key, :connection

  def initialize(api_key: ENV["OPENALEX_API_KEY"], connection: nil)
    raise ArgumentError, "OPENALEX_API_KEY is required" if api_key.blank?

    @api_key = api_key
    @connection = connection || build_connection
  end

  def each_topic_page
    return enum_for(:each_topic_page) unless block_given?

    cursor = "*"
    loop do
      page = get("topics", cursor: cursor, per_page: PER_PAGE)
      yield page.fetch("results")
      cursor = page.dig("meta", "next_cursor")
      break if cursor.blank?
    end
  end

  def works_by_dois(dois)
    normalized = dois.filter_map { |doi| normalize_doi(doi) }.uniq
    return [] if normalized.empty?

    normalized.each_slice(DOIS_PER_REQUEST).flat_map do |batch|
      get(
        "works",
        filter: "doi:#{batch.join('|').gsub(',', '%2C')}",
        per_page: PER_PAGE,
        select: "id,doi,display_name,type,primary_topic,topics"
      ).fetch("results")
    end
  end

  def get(path, params = {})
    response = connection.get(path, params.merge(api_key: api_key))
    unless response.success?
      raise RequestError, "OpenAlex request failed with HTTP #{response.status}"
    end

    JSON.parse(response.body)
  rescue JSON::ParserError
    raise RequestError, "OpenAlex returned invalid JSON"
  rescue Faraday::Error => error
    raise RequestError, "OpenAlex request failed: #{error.class}"
  end

  def normalize_doi(value)
    normalized = value.to_s.strip
    return if normalized.match?(DOI_IMAGE_URL_PATTERN)

    normalized = normalized.downcase
      .sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}, "")
      .sub(/\Adoi:\s*/, "")
      .sub(/[.,;:]+\z/, "")
    normalized = URI::DEFAULT_PARSER.unescape(normalized)
    normalized = strip_unmatched_closing_delimiters(normalized)
    return if normalized.match?(DOI_IMAGE_SUFFIX_PATTERN)
    normalized if normalized.match?(DOI_PATTERN)
  end

  def strip_unmatched_closing_delimiters(value)
    {
      ")" => "(",
      "]" => "[",
      "}" => "{",
    }.each do |closing, opening|
      value = value.chop while value.end_with?(closing) && value.count(closing) > value.count(opening)
    end
    value
  end

  def build_connection
    Faraday.new(url: BASE_URL) do |faraday|
      faraday.headers["User-Agent"] = "science.ecosyste.ms"
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
