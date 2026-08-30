class ProjectDependency < ApplicationRecord
  belongs_to :project
  belongs_to :package, optional: true

  validates :ecosystem, :package_name, presence: true
  validates :package_id,
    uniqueness: { scope: :project_id },
    if: -> { package_id.present? }
  validates :purl,
    uniqueness: { scope: %i[project_id package_id] },
    if: -> { package_id.nil? && purl.present? }
  validates :package_name,
    uniqueness: { scope: %i[project_id ecosystem package_id purl] },
    if: -> { package_id.nil? && purl.nil? }

  before_validation :normalize_identity

  def normalize_identity
    self.ecosystem = ecosystem.to_s.strip.downcase if ecosystem.present?
    if purl.blank?
      self.purl = nil
      return
    end

    parsed = Purl.parse(purl)
    self.purl = parsed.with(version: nil, subpath: nil).to_s
  rescue Purl::Error => error
    errors.add(:purl, error.message)
  end
end
