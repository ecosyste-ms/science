class Owner < ApplicationRecord
  ACADEMIC_DOMAINS = ScienceScoreCalculator::ACADEMIC_DOMAINS

  belongs_to :host
  has_many :projects, foreign_key: 'owner_id'

  counter_culture :host, column_name: :owners_count

  validates :login, presence: true
  validates :login, uniqueness: { scope: :host_id, case_sensitive: false }
  validates :uuid, uniqueness: { scope: :host_id }, allow_nil: true

  scope :organizations, -> { where(kind: 'organization') }
  scope :institutional, -> {
    # Build SQL conditions to match any academic domain
    conditions = ACADEMIC_DOMAINS.map { |domain| "LOWER(website) LIKE '%#{sanitize_sql_like(domain)}%'" }.join(' OR ')
    organizations.where("website IS NOT NULL AND website != '' AND (#{conditions})")
  }

  def institutional?
    return false unless kind == 'organization'
    return false unless website.present?

    domain = extract_domain(website)
    return false unless domain

    ACADEMIC_DOMAINS.any? { |academic_domain| domain.include?(academic_domain) }
  end

  def extract_domain(url)
    begin
      uri = URI.parse(url.start_with?('http') ? url : "https://#{url}")
      uri.host&.downcase
    rescue
      url.gsub(/^(https?:\/\/)?(www\.)?/, '').split('/').first&.downcase
    end
  end
end
