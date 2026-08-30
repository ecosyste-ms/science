class Package < ApplicationRecord
  belongs_to :package_registry
  belongs_to :published_by_project, class_name: "Project", optional: true

  has_many :project_dependencies, dependent: :nullify
  has_many :dependent_projects, through: :project_dependencies, source: :project

  validates :name, presence: true
  validates :name, uniqueness: { scope: :package_registry_id }
  validates :ecosystems_id, uniqueness: true, allow_nil: true
  validates :purl, uniqueness: true, allow_nil: true

  before_validation :normalize_purl

  def normalize_purl
    if purl.blank?
      self.purl = nil
      return
    end

    parsed = Purl.parse(purl)
    self.purl = parsed.with(version: nil, subpath: nil).to_s
    if package_registry && parsed.type != package_registry.purl_type
      errors.add(:purl, "type must match the package registry")
    end
  rescue Purl::Error => error
    errors.add(:purl, error.message)
  end
end
