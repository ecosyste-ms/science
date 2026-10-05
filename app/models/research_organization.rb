class ResearchOrganization < ApplicationRecord
  ROR_ID = %r{\Ahttps://ror\.org/0[a-z0-9]{6}[0-9]{2}\z}

  belongs_to :current_import, class_name: "ResearchOrganizationImport", optional: true
  belongs_to :pending_import, class_name: "ResearchOrganizationImport", optional: true
  has_many :owner_research_organizations
  has_many :owners, through: :owner_research_organizations

  validates :ror_id, format: { with: ROR_ID }

  scope :available, -> { where.not(current_import_id: nil) }
  scope :current, -> { where(current_import_id: ResearchOrganizationImport.where(current: true).select(:id)) }
  scope :active, -> { current.where("metadata ->> 'status' = ?", "active") }

  def to_param
    ror_id.delete_prefix("https://ror.org/")
  end

  def countries
    locations.filter_map do |location|
      details = location["geonames_details"]
      { code: details["country_code"], name: details["country_name"] } if details && details["country_code"]
    end.uniq
  end

  def display_name
    metadata.fetch("names", []).find { |name| name.fetch("types", []).include?("ror_display") }&.fetch("value")
  end

  def locations
    metadata.fetch("locations", [])
  end

  def country_codes
    locations.filter_map { |location| location.dig("geonames_details", "country_code") }.uniq
  end

  def descendants
    import_id = ResearchOrganizationImport.where(current: true).pick(:id)
    return self.class.none unless import_id

    sql = self.class.sanitize_sql_array([<<~SQL, ror_id, import_id])
      WITH RECURSIVE descendants(ror_id) AS (
        SELECT ?::varchar
        UNION
        SELECT relationships.related_ror_id
        FROM research_organization_relationships relationships
        JOIN descendants ON relationships.ror_id = descendants.ror_id
        WHERE relationships.research_organization_import_id = ? AND relationships.kind = 'child'
      )
      SELECT ror_id FROM descendants
    SQL
    self.class.current.where("ror_id IN (#{sql})").where.not(ror_id: ror_id)
  end
end
