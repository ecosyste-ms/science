class PackagePaper < ApplicationRecord
  MODEL_ROLES = %w[model_paper model_family_paper].freeze
  ROLES = (MODEL_ROLES + %w[base_model_paper method training_data evaluation reference]).freeze

  belongs_to :package
  belongs_to :paper

  validates :role, inclusion: { in: ROLES }, uniqueness: { scope: [:package_id, :paper_id] }
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
    raise ArgumentError, "Expected an array of verified package-paper relationships" unless rows.is_a?(Array)

    counts = { created: 0, updated: 0, unchanged: 0 }
    transaction do
      rows.each do |row|
        package = package_for_purl!(row.fetch("purl"))
        paper = Paper.resolve_openalex_id!(row.fetch("openalex_id"))
        role = row.fetch("role")
        evidence = row.fetch("evidence")
        candidate = new(package: package, paper: paper, role: role, evidence: evidence)
        candidate.evidence_has_sources
        candidate.errors.add(:role, "is not included in the list") unless ROLES.include?(role)
        raise ActiveRecord::RecordInvalid, candidate if candidate.errors.any?

        pair = lock.find_or_initialize_by(package: package, paper: paper, role: role)
        pair.evidence = (pair.evidence + evidence).uniq
        outcome = pair.new_record? ? :created : (pair.changed? ? :updated : :unchanged)
        pair.save! if pair.changed?
        counts[outcome] += 1
      end
    end
    counts
  end

  def self.package_for_purl!(value)
    Package.resolve_purl!(value)
  end
end
