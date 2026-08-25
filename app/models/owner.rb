class Owner < ApplicationRecord
  belongs_to :host
  has_many :projects, foreign_key: 'owner_id'

  counter_culture :host, column_name: :owners_count

  validates :login, presence: true
  validates :login, uniqueness: { scope: :host_id, case_sensitive: false }
  validates :uuid, uniqueness: { scope: :host_id }, allow_nil: true

  scope :hidden, -> { where(hidden: true) }
  scope :visible, -> { where(hidden: [false, nil]) }
  scope :organizations, -> { where(kind: 'organization') }
  scope :institutional, -> { organizations.visible.where.not(institutional_domain: nil) }

  before_validation :classify_research_organization_domain,
    if: -> { new_record? || will_save_change_to_website? || will_save_change_to_kind? }

  def self.reclassify_research_organizations!(scope: all, progress: nil)
    counts = { processed: 0, institutional: 0, updated: 0 }
    scope.find_each(batch_size: 500) do |owner|
      attributes = owner.research_organization_classification
      changes = attributes.select { |key, value| owner.public_send(key) != value }
      owner.update_columns(changes) if changes.any?
      counts[:processed] += 1
      counts[:updated] += 1 if changes.any?
      counts[:institutional] += 1 if attributes.fetch(:institutional_domain).present?
      progress&.call("Reclassified #{counts[:processed]} owners") if (counts[:processed] % 5_000).zero?
    end
    counts
  end

  def institutional?
    kind == 'organization' && institutional_domain.present?
  end

  def institutional_match
    return unless kind == 'organization'

    ResearchOrganizationDomainMatcher.match(website_domain)
  end

  def website_domain
    ResearchOrganizationDomainMatcher.domain_from_url(website)
  end

  def classify_research_organization_domain
    assign_attributes(research_organization_classification)
  end

  def research_organization_classification
    match = kind == 'organization' ? ResearchOrganizationDomainMatcher.match(website_domain) : nil
    {
      institutional_domain: match&.fetch(:domain),
    }
  end

  def hide!
    update!(
      hidden: true,
      name: nil,
      uuid: nil,
      description: nil,
      email: nil,
      website: nil,
      location: nil,
      twitter: nil,
      company: nil,
      icon_url: nil,
      repositories_count: 0,
      last_synced_at: nil,
      metadata: {},
      total_stars: nil,
      followers: nil,
      following: nil
    )
  end

end
