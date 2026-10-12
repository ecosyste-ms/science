class PackageProject < ApplicationRecord
  CODE_ROLES = %w[model_implementation inference_implementation model_library].freeze
  ROLES = (CODE_ROLES + %w[supported_runtime]).freeze

  belongs_to :package
  belongs_to :project

  validates :role, inclusion: { in: ROLES }, uniqueness: { scope: [:package_id, :project_id] }
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
    unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
      raise ArgumentError, "Expected an array of reviewed package-project relationships"
    end

    counts = { created: 0, updated: 0, unchanged: 0 }
    transaction do
      rows.each do |row|
        package = Package.resolve_purl!(row.fetch("purl"))
        project = Project.resolve_repository_url!(row.fetch("repository_url"))
        role = row.fetch("role")
        evidence = row.fetch("evidence")
        candidate = new(package: package, project: project, role: role, evidence: evidence)
        candidate.evidence_has_sources
        candidate.errors.add(:role, "is not included in the list") unless ROLES.include?(role)
        raise ActiveRecord::RecordInvalid, candidate if candidate.errors.any?

        pair = lock.find_or_initialize_by(package: package, project: project, role: role)
        pair.evidence = (pair.evidence + evidence).uniq
        outcome = pair.new_record? ? :created : (pair.changed? ? :updated : :unchanged)
        pair.save! if pair.changed?
        counts[outcome] += 1
      end
    end
    counts
  end
end
