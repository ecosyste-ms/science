class ProjectPaper < ApplicationRecord
  belongs_to :project
  belongs_to :paper

  validates :role, inclusion: { in: %w[implementation reference] }

  validates :paper_id, uniqueness: { scope: :project_id }
  validate :evidence_has_sources

  def evidence_has_sources
    unless evidence.is_a?(Array) && evidence.any? && evidence.all? { |item|
      item.is_a?(Hash) && item["source"].is_a?(String) && item["source"].present? &&
        item["url"].is_a?(String) && item["url"].present?
    }
      errors.add(:evidence, "must contain sources with a source name and URL")
    end
  end

  def self.import_verified!(rows)
    raise ArgumentError, "Expected an array of verified project-paper pairs" unless rows.is_a?(Array)

    counts = { created: 0, updated: 0, unchanged: 0 }
    transaction do
      rows.each do |row|
        project = project_for_url!(row.fetch("repository_url"))
        paper = paper_for_openalex_id!(row.fetch("openalex_id"))
        evidence = row.fetch("evidence")
        candidate = new(project: project, paper: paper, evidence: evidence)
        candidate.evidence_has_sources
        raise ActiveRecord::RecordInvalid, candidate if candidate.errors.any?

        pair = lock.find_or_initialize_by(project: project, paper: paper)
        pair.role = "implementation"
        pair.evidence = (pair.evidence + evidence).uniq
        outcome = pair.new_record? ? :created : (pair.changed? ? :updated : :unchanged)
        pair.save! if pair.changed?
        counts[outcome] += 1
      end
    end
    counts
  end

  def self.project_for_url!(value)
    Project.resolve_repository_url!(value)
  end

  def self.paper_for_openalex_id!(value)
    Paper.resolve_openalex_id!(value)
  end
end
