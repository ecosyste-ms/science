class Paper < ApplicationRecord
  has_many :mentions, dependent: :destroy
  has_many :projects, through: :mentions
  has_many :project_papers, dependent: :delete_all
  has_many :linked_projects, through: :project_papers, source: :project
  has_many :paper_authors, dependent: :delete_all
  has_many :package_papers, dependent: :delete_all

  def linked_packages
    Package.where(id: package_papers.select(:package_id))
  end

  def self.resolve_openalex_id!(value)
    match = value.to_s.strip.match(%r{\A(?:https?://openalex\.org/)?(W\d+)\z}i)
    raise ArgumentError, "Invalid OpenAlex Work ID: #{value.inspect}" unless match

    id = match[1].downcase
    papers = where("lower(openalex_id) IN (?)", [id, "https://openalex.org/#{id}"])
      .limit(2).to_a
    raise ArgumentError, "Expected one existing paper for #{id.upcase}, found #{papers.size}" unless papers.one?

    papers.first
  end

  def to_s
    title.presence || doi.presence || "Untitled paper"
  end

  def self.import_openalex!(work)
    work = work.except("relevance_score")
    id = work.fetch("id")
    raise ArgumentError, "Invalid OpenAlex Work ID" unless id.is_a?(String) && id.match?(%r{\Ahttps://openalex\.org/W\d+\z})
    raise ArgumentError, "Missing paper title" unless work["title"].is_a?(String) && work["title"].present?

    doi = work["doi"].presence&.downcase&.sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}, "")
    raise ArgumentError, "Invalid paper DOI" if doi && !doi.match?(%r{\A10\.\d{4,9}/\S+\z})
    ids = [id.downcase, id.sub("https:", "http:").downcase, id.split("/").last.downcase]
    dois = doi ? [doi, "https://doi.org/#{doi}", "http://doi.org/#{doi}", "https://dx.doi.org/#{doi}", "http://dx.doi.org/#{doi}"] : []

    transaction do
      # Serialize imports sharing either identifier, including DOI-only papers.
      ([id] + [doi].compact).sort.each do |key|
        connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{connection.quote("paper:#{key}")}, 0))")
      end
      matches = where("lower(openalex_id) IN (?)", ids)
      matches = matches.or(where("lower(doi) IN (?)", dois)) if doi
      papers = matches.limit(2).to_a
      raise ArgumentError, "Multiple papers match #{id}" if papers.size > 1
      paper = papers.first || new
      if paper.openalex_id.present? && !ids.include?(paper.openalex_id.downcase)
        raise ArgumentError, "DOI belongs to another OpenAlex Work"
      end
      if doi && paper.doi.present? && !dois.include?(paper.doi.downcase)
        raise ArgumentError, "OpenAlex Work has a different stored DOI"
      end
      urls = Array(work["locations"]).flat_map { |location| [location["landing_page_url"], location["pdf_url"]] }.compact
      paper.assign_attributes(openalex_id: id, title: work["title"], openalex_data: work,
        publication_date: work["publication_date"].presence && Date.iso8601(work["publication_date"]),
        urls: (Array(paper.urls) + urls).uniq)
      paper.doi = doi if doi
      status = paper.new_record? ? "created" : paper.changed? ? "updated" : "unchanged"
      if paper.changed?
        paper.last_synced_at = Time.current
        paper.save!
      end
      { "status" => status, "paper_id" => paper.id }
    end
  end

  def external_url
    return "https://doi.org/#{doi.sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}i, '')}" if doi.present?
    return "https://openalex.org/#{openalex_id.split('/').last}" if openalex_id.present?
    urls.find { |url| url.match?(%r{\Ahttps?://}i) }
  end
end
