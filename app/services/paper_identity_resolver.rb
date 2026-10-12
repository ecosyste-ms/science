class PaperIdentityResolver
  attr_reader :client, :lookups, :sources

  def initialize(client: nil)
    @client = client || OpenAlexApiClient.new
    unless client
      @client.connection.options.open_timeout = 5
      @client.connection.options.timeout = 20
    end
    @lookups = {}
    @sources = {}
  end

  def call(candidates)
    raise ArgumentError, "Expected an array of citation candidates" unless candidates.is_a?(Array) && candidates.all? { |row| row.is_a?(Hash) }

    results = candidates.map { |row| resolve(row) }
    { "generated_at" => Time.current.iso8601,
      "summary" => results.group_by { |row| row.fetch("assessment") }.transform_values(&:size),
      "candidates" => results, "lookups" => lookups, "sources" => sources }
  end

  def resolve(row)
    result = { "input" => row }
    kind = row.fetch("identifier_kind")
    identifier = row.fetch("identifier")
    raise ArgumentError, "Expected a nonempty identifier" unless identifier.is_a?(String) && identifier.present?

    case kind
    when "arxiv"
      id = arxiv_id(identifier)
      result["source"] = "arxiv:#{id}"
      source = source_metadata("arxiv", id)
      doi = "10.48550/arxiv.#{id.downcase}"
    when "acl_id"
      raise ArgumentError, "Invalid ACL identifier" unless identifier.match?(/\A(?:[A-Z]\d{2}-\d+|\d{4}\.[\w-]+\.\d+)\z/i)
      result["source"] = "acl_id:#{identifier}"
      source = source_metadata(kind, identifier)
      doi = source.dig("metadata", "citation_doi")&.first
      return result.merge("assessment" => "needs_review", "reason" => "Publication DOI unavailable") unless doi.present?
    when "doi"
      doi = normalize_doi(identifier)
      if doi.start_with?("10.48550/arxiv.")
        id = arxiv_id(doi.delete_prefix("10.48550/arxiv."))
        result["source"] = "arxiv:#{id}"
        source = source_metadata("arxiv", id)
        doi = "10.48550/arxiv.#{id.downcase}"
      end
    when "openalex_id"
      match = identifier.match(%r{\A(?:https?://openalex\.org/)?(W\d+)\z}i)
      raise ArgumentError, "Invalid OpenAlex Work ID" unless match
      work_id = match[1].upcase
    else
      return result.merge("assessment" => "unsupported", "reason" => "No exact identifier lookup for this reference type")
    end

    key = work_id || "doi:#{normalize_doi(doi)}"
    result["lookup"] = key
    lookup = lookup_work(key)
    return result.merge("assessment" => lookup.fetch("status")) unless lookup["status"] == "found"

    work = lookup.fetch("work")
    titles = Array(source&.dig("metadata", "citation_title"))
    title_source = titles.any? ? result["source"] : "citation"
    occurrences = row.fetch("occurrences", [])
    raise ArgumentError, "Expected an array of citation occurrences" unless occurrences.is_a?(Array) && occurrences.all? { |item| item.is_a?(Hash) }
    titles = occurrences.filter_map { |item| item["title"] if item["title"].is_a?(String) }.uniq if titles.empty?
    titles = titles.reject { |title| normalize_title(title).empty? }
    authors = Array(source&.dig("metadata", "citation_author"))
    author_source = result["source"] if authors.any?
    if authors.empty?
      citation_authors = occurrences.filter_map do |item|
        value = item.dig("fields", "author")
        if value.is_a?(String)
          BibTeX::Names.parse(value)&.map(&:to_s).presence
        else
          names = item.dig("brief_entry", "authors")
          if names.is_a?(Array) && names.all? { |name| name.is_a?(Hash) }
            parsed = names.map { |name| [name["given_names"], name["family_names"]].compact.join(" ") }
            parsed.presence if parsed.all?(&:present?)
          end
        end
      end.uniq
      if citation_authors.one?
        authors = citation_authors.first
        author_source = "citation"
      end
    end
    work_authors = Array(work["authorships"]).filter_map do |author|
      next unless author.is_a?(Hash)
      author["raw_author_name"].presence || author.dig("author", "display_name")
    end
    checks = {
      "title" => titles.empty? ? nil : titles.any? { |title| normalize_title(title) == normalize_title(work["title"]) },
      "authors" => authors.empty? || work_authors.empty? ? nil : normalize_authors(authors) == normalize_authors(work_authors)
    }
    assessment = if checks.values.include?(false)
      "metadata_conflict"
    elsif checks.values.all?(true)
      "metadata_agrees"
    else
      "needs_review"
    end
    result.merge("assessment" => assessment, "checks" => checks,
      "comparison_sources" => { "title" => title_source, "authors" => author_source },
      "compared_titles" => titles, "compared_authors" => authors)
  rescue ArgumentError, KeyError => error
    result.merge("assessment" => "invalid", "reason" => error.message)
  end

  def arxiv_id(value)
    id = value.strip.sub(/\Aarxiv:/i, "")
    raise ArgumentError, "Invalid arXiv identifier" unless Identifiers::ArxivId.extract(id) == [id]
    id.sub(/v\d+\z/i, "")
  end

  def normalize_doi(value)
    doi = client.normalize_doi(value)
    raise ArgumentError, "Invalid DOI" unless doi && doi.split("/").none? { |part| %w[. ..].include?(part) }
    doi
  end

  def lookup_work(key)
    lookups[key] ||= begin
      path = URI::DEFAULT_PARSER.escape(key, /[^a-zA-Z0-9._~:\/-]/)
      work = client.get("works/#{path}")
      if work.is_a?(Hash) && work["id"].to_s.match?(%r{\Ahttps://openalex\.org/W\d+\z}) && work["title"].is_a?(String) && work["title"].present?
        { "status" => "found", "retrieved_at" => Time.current.iso8601, "work" => work }
      else
        { "status" => "error", "reason" => "Invalid OpenAlex Work response" }
      end
    rescue OpenAlexApiClient::RequestError => error
      { "status" => error.status == 404 ? "not_found" : "error", "reason" => error.message }
    end
  end

  def source_metadata(kind, id)
    sources["#{kind}:#{id}"] ||= begin
      url = kind == "arxiv" ? "https://arxiv.org/abs/#{id}" : "https://aclanthology.org/#{id}/"
      response = Faraday.get(url) do |request|
        request.headers["User-Agent"] = "science.ecosyste.ms"
        request.options.open_timeout = 5
        request.options.timeout = 20
      end
      source = { "url" => url, "http_status" => response.status, "retrieved_at" => Time.current.iso8601 }
      if response.status == 200
        metadata = Nokogiri::HTML(response.body, nil, "UTF-8").css('meta[name^="citation_"]')
          .group_by { |tag| tag["name"] }.transform_values { |tags| tags.filter_map { |tag| tag["content"].presence } }
        source["metadata"] = metadata
      end
      source
    rescue Faraday::Error => error
      { "url" => url, "error" => error.class.name }
    end
  end

  def normalize_title(value)
    value.to_s.unicode_normalize(:nfkd).downcase.gsub(/[\p{M}\p{P}\p{Z}\s]/, "")
  end

  def normalize_authors(values)
    values.map { |value| value.to_s.unicode_normalize(:nfkd).downcase.gsub(/\p{M}/, "").scan(/[\p{L}\p{N}]+/).sort }.sort
  end
end
