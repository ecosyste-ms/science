class ProjectExternalSoftwareRecord < ApplicationRecord
  belongs_to :project
  belongs_to :external_software_record

  scope :research_registry_matches, -> {
    joins(:external_software_record)
      .where("LOWER(project_external_software_records.match_status) = ?", "matched")
      .where("LOWER(external_software_records.source) IN (?)", %w[ascl biotools swmath rrid])
      .where("LOWER(external_software_records.status) IN (?)", %w[ok error])
      .where.not(external_software_records: { retrieved_at: nil })
  }

  def self.registry_references
    joins(:external_software_record).where(match_status: "matched")
      .where(external_software_records: { status: %w[ok error], source: %w[wikidata biotools ascl swmath rrid doi] })
      .where.not(external_software_records: { retrieved_at: nil })
      .order("external_software_records.source", "external_software_records.identifier")
      .pluck("external_software_records.source", "external_software_records.identifier", "external_software_records.concept_identifier")
      .map { |source, identifier, concept| [source, source == "doi" ? (concept.presence || identifier) : identifier] }
      .uniq.filter_map do |source, identifier|
        url = ExternalSoftwareRecord.new(source: source, identifier: identifier).record_url
        label = source == "doi" ? (identifier.start_with?("10.5281/zenodo.") ? "Zenodo" : "DOI") : ExternalSoftwareRecord.source_name(source)
        { source: label, identifier: identifier, url: url } if url
      end
  end

  def self.scientific_source_counts
    joins(:external_software_record)
      .where(project_id: Project.visible.scientific.select(:id), match_status: "matched")
      .where(external_software_records: { status: %w[ok error] })
      .where.not(external_software_records: { retrieved_at: nil })
      .group("external_software_records.source").distinct.count(:project_id)
      .sort_by { |source, count| [-count, source] }
  end

  def as_json(*)
    record = external_software_record
    {
      id: id, scheme: record.source, identifier: record.identifier, record_url: record.record_url,
      relationship: relationship, match_status: match_status, evidence: evidence,
      source_status: record.status, retrieved_at: record.retrieved_at,
      attempted_at: record.attempted_at, next_refresh_at: record.next_refresh_at,
      last_error: record.last_error, collection_url: record.collection_url, metadata: record.metadata,
      concept_identifier: record.concept_identifier,
    }
  end
end
