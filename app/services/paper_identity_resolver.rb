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
    @searches = {}
  end

  def call(candidates)
    raise ArgumentError, "Expected an array of citation candidates" unless candidates.is_a?(Array) && candidates.all? { |row| row.is_a?(Hash) }

    results = candidates.map { |row| resolve(row) }
    { "generated_at" => Time.current.iso8601,
      "summary" => results.group_by { |row| row.fetch("assessment") }.transform_values(&:size),
      "candidates" => results, "lookups" => lookups, "sources" => sources, "searches" => @searches }
  end

  def resolve(row)
    result = { "input" => row }
    kind = row.fetch("identifier_kind")
    identifier = row.fetch("identifier")
    raise ArgumentError, "Expected a nonempty identifier" unless identifier.is_a?(String) && identifier.present?

    case kind
    when "citation_title"
      return resolve_title(row)
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
    when "pmid"
      raise ArgumentError, "Invalid PubMed identifier" unless identifier.match?(/\A[1-9]\d*\z/)
      work_id = "pmid:#{identifier}"
    else
      return result.merge("assessment" => "unsupported", "reason" => "No exact identifier lookup for this reference type")
    end

    key = work_id || "doi:#{normalize_doi(doi)}"
    result["lookup"] = key
    lookup = lookup_work(key)
    return result.merge("assessment" => lookup.fetch("status")) unless lookup["status"] == "found"

    result.merge(compare(row, lookup.fetch("work"), source: source, source_key: result["source"]))
  rescue ArgumentError, KeyError => error
    result.merge("assessment" => "invalid", "reason" => error.message)
  end

  def compare(row, work, source: nil, source_key: nil)
    titles = Array(source&.dig("metadata", "citation_title"))
    title_source = titles.any? ? source_key : "citation"
    occurrences = row.fetch("occurrences", [])
    raise ArgumentError, "Expected an array of citation occurrences" unless occurrences.is_a?(Array) && occurrences.all? { |item| item.is_a?(Hash) }
    titles = occurrences.filter_map { |item| item["title"] if item["title"].is_a?(String) }.uniq if titles.empty?
    titles = titles.reject { |title| normalize_title(title).empty? }
    authors = Array(source&.dig("metadata", "citation_author"))
    author_source = source_key if authors.any?
    if authors.empty?
      citation_authors = occurrences.filter_map do |item|
        value = item.dig("fields", "author")
        names = item.dig("brief_entry", "authors")
        if names.is_a?(Array) && names.any? && names.all? { |name| name.is_a?(Hash) && name["family_names"].present? }
          names.map { |name| [name["given_names"], name["family_names"]].compact.join(" ") }
        elsif value.is_a?(String)
          BibTeX::Names.parse(value)&.map(&:to_s).presence
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
      "authors" => authors.empty? || work_authors.empty? ? nil : authors_match?(authors, work_authors)
    }
    assessment = if checks.values.include?(false)
      "metadata_conflict"
    elsif checks.values.all?(true)
      "metadata_agrees"
    else
      "needs_review"
    end
    { "assessment" => assessment, "checks" => checks,
      "comparison_sources" => { "title" => title_source, "authors" => author_source },
      "compared_titles" => titles, "compared_authors" => authors, "work_authors" => work_authors }
  end

  def resolve_title(row)
    title = row.fetch("identifier")
    result = { "input" => row, "search" => title }
    occurrences = row.fetch("occurrences", [])
    raise ArgumentError, "Expected an array of citation occurrences" unless occurrences.is_a?(Array) && occurrences.all? { |item| item.is_a?(Hash) }
    years = occurrences.flat_map { |item| [item.dig("fields", "year"), item.dig("brief_entry", "year")] }
      .compact.map(&:to_s).uniq
    unless years.one? && years.first.match?(/\A\d{4}\z/)
      return result.merge("assessment" => "needs_review", "reason" => "One citation year is required for title search")
    end
    search = search_title(title)
    return result.merge("assessment" => search.fetch("status"), "reason" => search["reason"]) unless search["status"] == "found"

    comparisons = search.fetch("works").map do |work|
      comparison = compare(row.merge("occurrences" => occurrences + [{ "title" => title }]), work)
      comparison["checks"]["title"] = normalize_title(title) == normalize_title(work["title"])
      comparison["checks"]["year"] = work["publication_year"].to_s == years.first
      comparison["assessment"] = "metadata_conflict" if comparison["checks"].values.include?(false)
      comparison.merge("openalex_id" => work["id"])
    end
    result["matches"] = comparisons
    matches = comparisons.select { |comparison| comparison["checks"].values.all?(true) }
    unless matches.one?
      return result.merge("assessment" => "needs_review", "reason" => matches.empty? ? "No title, author and year match" : "Multiple title, author and year matches")
    end
    work = search["works"].find { |item| item["id"] == matches.first["openalex_id"] }
    key = work.fetch("id").split("/").last
    lookups[key] ||= { "status" => "found", "retrieved_at" => search.fetch("retrieved_at"), "work" => work }
    result.merge(matches.first.except("openalex_id"), "lookup" => key, "assessment" => "metadata_agrees")
  end

  def search_title(title)
    @searches[title] ||= begin
      query = LaTeX.decode(title).scan(/[\p{L}\p{N}]+/).join(" ")
      raise ArgumentError, "Invalid citation title" if query.blank?
      response = client.get("works", "search.title" => query, per_page: 100)
      works = response["results"]
      count = response.dig("meta", "count")
      unless works.is_a?(Array) && count.is_a?(Integer) && count >= works.size && works.all? { |work| valid_work?(work) }
        raise ArgumentError, "Invalid OpenAlex title search response"
      end
      if count > works.size
        { "status" => "needs_review", "reason" => "Title search results are incomplete", "count" => count }
      else
        { "status" => "found", "retrieved_at" => Time.current.iso8601, "works" => works.uniq { |work| work["id"] } }
      end
    rescue OpenAlexApiClient::RequestError, ArgumentError => error
      { "status" => "error", "reason" => error.message }
    end
  end

  def valid_work?(work)
    work.is_a?(Hash) && work["id"].to_s.match?(%r{\Ahttps://openalex\.org/W\d+\z}) && work["title"].is_a?(String) && work["title"].present?
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
      if valid_work?(work)
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

  def authors_match?(authors, work_authors)
    left = normalize_authors(authors)
    right = normalize_authors(work_authors)
    return false unless left.size == right.size
    return true if left.sort == right.sort

    short_left = normalize_authors(authors, omit_middle_initials: true)
    short_right = normalize_authors(work_authors, omit_middle_initials: true)
    remaining = (0...right.size).to_a
    left.each_with_index.all? do |name, index|
      matches = remaining.select { |other| name == right[other] || short_left[index] == right[other] || name == short_right[other] }
      matches.one? && remaining.delete(matches.first)
    end
  end

  def normalize_authors(values, omit_middle_initials: false)
    values.map do |value|
      decoded = LaTeX.decode(value.to_s).unicode_normalize(:nfkd).gsub(/\p{M}/, "")
      name = BibTeX::Names.parse(decoded)&.first
      next decoded.downcase.scan(/[\p{L}\p{N}]+/).sort unless name

      given = name.given.to_s.scan(/[\p{L}\p{N}]+/)
      given = given.first(1) + given.drop(1).reject { |part| part.length == 1 } if omit_middle_initials
      (given + [name.prefix, name.family, name.suffix].compact.join(" ").scan(/[\p{L}\p{N}]+/)).map(&:downcase).sort
    end
  end
end
