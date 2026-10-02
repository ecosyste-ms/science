class ProjectExternalSoftwareRecord < ApplicationRecord
  belongs_to :project
  belongs_to :external_software_record

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
      id: id, scheme: record.source, identifier: record.identifier,
      relationship: relationship, match_status: match_status, evidence: evidence,
      source_status: record.status, retrieved_at: record.retrieved_at,
      attempted_at: record.attempted_at, next_refresh_at: record.next_refresh_at,
      last_error: record.last_error, metadata: record.metadata,
    }
  end
end
