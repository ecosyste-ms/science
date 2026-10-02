class ProjectExternalSoftwareRecord < ApplicationRecord
  belongs_to :project
  belongs_to :external_software_record

  def self.registry_references
    joins(:external_software_record).where(match_status: "matched")
      .where(external_software_records: { status: %w[ok error], source: %w[wikidata biotools ascl swmath rrid] })
      .where.not(external_software_records: { retrieved_at: nil })
      .order("external_software_records.source", "external_software_records.identifier")
      .pluck("external_software_records.source", "external_software_records.identifier").uniq.filter_map do |source, identifier|
        url = ExternalSoftwareRecord.new(source: source, identifier: identifier).record_url
        { source: ExternalSoftwareRecord.source_name(source), identifier: identifier, url: url } if url
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
      last_error: record.last_error, metadata: record.metadata,
    }
  end
end
