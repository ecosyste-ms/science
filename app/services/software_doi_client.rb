class SoftwareDoiClient
  API_URL = "https://api.datacite.org/dois"
  ZENODO_URL = "https://zenodo.org/api/records"
  METADATA_PARAMS = { affiliation: true, publisher: true, detail: true }.freeze
  PAGE_SIZE = 25

  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("Software DOI service rate limit or unavailable")
    end
  end

  def self.identifier(value)
    raise ArgumentError, "invalid DOI" unless value.is_a?(String)
    id = value.strip.sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}i, "").sub(/\Adoi:\s*/i, "").downcase
    raise ArgumentError, "invalid DOI" unless id.length <= 2000 && id.match?(%r{\A10\.[0-9]{4,9}/[^\s\x00-\x1f\x7f]+\z})
    raise ArgumentError, "invalid DOI" if id.split("/").any? { |segment| %w[. ..].include?(segment) }
    id
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 25 DOIs" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def self.escaped_identifier(id)
    URI::DEFAULT_PARSER.escape(identifier(id), /[^a-z0-9._~\/-]/)
  end

  def self.record_url(id)
    "https://doi.org/#{escaped_identifier(id)}"
  end

  def self.collection_url(id)
    "#{API_URL}/#{escaped_identifier(id)}?#{URI.encode_www_form(METADATA_PARAMS)}"
  end

  def record(id)
    id = self.class.identifier(id)
    response = request(self.class.collection_url(id), "datacite")
    data = parse(response)
    if response.status == 404 && data.is_a?(Hash) && data["errors"].is_a?(Array) &&
        data["errors"].one? && data["errors"].first.is_a?(Hash) && data["errors"].first["status"] == "404"
      return { "doi" => id, "missing" => true }
    end
    raise Error, "DataCite HTTP #{response.status}" unless response.status == 200
    resource = data["data"] if data.is_a?(Hash)
    raise Error, "Invalid DataCite DOI record" unless valid_datacite?(resource, id)
    result = { "doi" => id, "datacite" => resource }
    if resource.dig("attributes", "types", "resourceTypeGeneral").casecmp?("software") && id.match?(%r{\A10\.5281/zenodo\.[1-9][0-9]*\z})
      result["zenodo"] = zenodo_record(id)
      parents = resource["attributes"]["relatedIdentifiers"].filter_map do |item|
        next unless item["relationType"].casecmp?("IsVersionOf") && item["relatedIdentifierType"].casecmp?("DOI")
        self.class.identifier(item["relatedIdentifier"])
      rescue ArgumentError
        raise Error, "Invalid DataCite version relationship"
      end.uniq
      unless parents.empty? || parents == [self.class.identifier(result["zenodo"]["conceptdoi"])]
        raise Error, "Conflicting DataCite and Zenodo version relationships"
      end
    end
    result
  end

  def valid_datacite?(resource, id)
    return false unless resource.is_a?(Hash) && resource["type"] == "dois" && resource["attributes"].is_a?(Hash)
    attributes = resource["attributes"]
    return false unless self.class.identifier(resource["id"]) == id && self.class.identifier(attributes["doi"]) == id
    return false unless attributes["state"] == "findable" && attributes["isActive"] == true &&
      attributes["types"].is_a?(Hash) && attributes["types"]["resourceTypeGeneral"].is_a?(String)
    attributes["relatedIdentifiers"].is_a?(Array) && attributes["relatedIdentifiers"].all? do |item|
      item.is_a?(Hash) && %w[relatedIdentifier relatedIdentifierType relationType].all? { |key| item[key].is_a?(String) }
    end
  rescue ArgumentError
    false
  end

  def zenodo_record(id)
    url = "#{ZENODO_URL}/#{id.split('.').last}"
    3.times do
      response = request(url, "zenodo")
      if [301, 302].include?(response.status)
        uri = URI.join(url, response.headers["location"].to_s)
        unless uri.scheme == "https" && uri.host == "zenodo.org" && uri.port == 443 && uri.userinfo.nil? &&
            uri.path.match?(%r{\A/api/records/[1-9][0-9]*\z}) && uri.query.nil? && uri.fragment.nil?
          raise Error, "Invalid Zenodo record redirect"
        end
        url = uri.to_s
        next
      end
      raise Error, "Zenodo HTTP #{response.status}" unless response.status == 200
      record = parse(response)
      raise Error, "Invalid or mismatched Zenodo record" unless valid_zenodo?(record, id, url)
      return record
    end
    raise Error, "Too many Zenodo redirects"
  rescue URI::InvalidURIError
    raise Error, "Invalid Zenodo record redirect"
  end

  def valid_zenodo?(record, id, url)
    return false unless record.is_a?(Hash) && record["metadata"].is_a?(Hash)
    return false unless record["status"] == "published" && record["submitted"] == true
    doi = self.class.identifier(record["doi"])
    concept = self.class.identifier(record["conceptdoi"])
    return false unless [doi, concept].include?(id) && doi == "10.5281/zenodo.#{record['id']}" &&
      concept == "10.5281/zenodo.#{record['conceptrecid']}" && url == "#{ZENODO_URL}/#{record['id']}"
    metadata = record["metadata"]
    return false unless metadata.dig("resource_type", "type") == "software" &&
      (metadata["custom"].nil? || metadata["custom"].is_a?(Hash))
    related = metadata["related_identifiers"]
    related.nil? || (related.is_a?(Array) && related.all? do |item|
      item.is_a?(Hash) && %w[identifier scheme relation].all? { |key| item[key].is_a?(String) }
    end)
  rescue ArgumentError, TypeError
    false
  end

  def request(url, service)
    cache_key = "software-doi-#{service}-retry-at"
    cooldown = Rails.cache.read(cache_key)
    raise RateLimited, Time.at(cooldown).utc if cooldown && cooldown > Time.current.to_f
    response = Faraday.get(url, nil, { "Accept" => "application/json", "User-Agent" => "science.ecosyste.ms (+https://science.ecosyste.ms)" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 60
    end
    if [429, 503].include?(response.status)
      value = response.headers["retry-after"].to_s
      retry_at = value.match?(/\A[0-9]+\z/) ? Time.current + value.to_i : (Time.httpdate(value) rescue 5.minutes.from_now)
      retry_at = [retry_at, 1.minute.from_now, Time.at(Rails.cache.read(cache_key) || 0).utc].max
      Rails.cache.write(cache_key, retry_at.to_f, expires_in: (retry_at - Time.current).ceil + 60)
      raise RateLimited, retry_at
    end
    response
  rescue Faraday::Error => error
    raise Error, "Software DOI request failed: #{error.class.name}"
  end

  def parse(response)
    raise Error, "Software DOI response exceeds 5 MB" if response.body.bytesize > 5.megabytes
    JSON.parse(response.body)
  rescue JSON::ParserError
    raise Error, "Invalid software DOI response"
  end
end
