class JournalPaperResolver
  class IdentityConflict < StandardError; end

  attr_reader :client

  def initialize(client: nil)
    @client = client || OpenAlexApiClient.new
    @client.connection.options.open_timeout = 5
    @client.connection.options.timeout = 20
  end

  def resolve(paper)
    if paper.openalex_id.present?
      id = paper.openalex_id.match(%r{\A(?:https?://openalex\.org/)?(W\d+)\z}i)&.[](1)&.upcase
      raise IdentityConflict, "Invalid stored OpenAlex ID" unless id
      work = client.get("works/#{id}")
      validate_work!(work)
      raise IdentityConflict, "OpenAlex Work ID changed" unless work["id"].split("/").last == id
    elsif paper.doi.present?
      doi = client.normalize_doi(paper.doi)
      raise IdentityConflict, "Invalid stored DOI" unless doi && doi.split("/").none? { |part| %w[. ..].include?(part) }
      path = URI::DEFAULT_PARSER.escape("doi:#{doi}", /[^a-zA-Z0-9._~:\/-]/)
      work = client.get("works/#{path}")
      validate_work!(work)
      raise IdentityConflict, "OpenAlex DOI does not match the requested paper" unless client.normalize_doi(work["doi"]) == doi
    else
      work = find_by_publisher(paper)
    end
    work
  end

  def find_by_publisher(paper)
    identities = paper.paper_identifiers.where(source: JournalPaperEnrichment::SOURCES).map do |identity|
      { source: identity.source, identifier: identity.identifier }
    end
    raise IdentityConflict, "Missing publisher identifier" if identities.empty?
    query = LaTeX.decode(paper.title.to_s).scan(/[\p{L}\p{N}]+/).join(" ")
    raise IdentityConflict, "Missing or oversized paper title" unless query.length.between?(1, 1000)
    response = client.get("works", "search.title" => query, per_page: 100)
    works = response["results"]
    count = response.dig("meta", "count")
    unless works.is_a?(Array) && count.is_a?(Integer) && count >= works.size
      raise IdentityConflict, "Invalid OpenAlex search response"
    end
    raise IdentityConflict, "OpenAlex search results are incomplete" if count > works.size
    works.each { |work| validate_work!(work) }
    matches = works.uniq { |work| work.fetch("id") }.select do |work|
      (PaperIdentifier.from_urls(Paper.openalex_urls(work)) & identities).any?
    end
    raise IdentityConflict, "Multiple OpenAlex works match the publisher article" if matches.many?
    matches.first
  end

  def validate_work!(work)
    unless work.is_a?(Hash) && work["id"].is_a?(String) && work["id"].match?(%r{\Ahttps://openalex\.org/W\d+\z}) &&
        work["title"].is_a?(String) && work["title"].present?
      raise IdentityConflict, "Invalid OpenAlex Work response"
    end
    locations = work["locations"]
    unless locations.nil? || (locations.is_a?(Array) && locations.all? { |location| location.is_a?(Hash) })
      raise IdentityConflict, "Invalid OpenAlex locations"
    end
    [*locations, work["primary_location"], work["best_oa_location"]].compact.each do |location|
      unless location.is_a?(Hash) && %w[landing_page_url pdf_url].all? { |key| location[key].nil? || location[key].is_a?(String) }
        raise IdentityConflict, "Invalid OpenAlex location URL"
      end
    end
  end
end
