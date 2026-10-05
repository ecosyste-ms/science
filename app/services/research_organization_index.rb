class ResearchOrganizationIndex
  DISPLAY_NAME_SQL = "(SELECT names.entry ->> 'value' FROM jsonb_array_elements(research_organizations.metadata -> 'names') " \
    "AS names(entry) WHERE names.entry -> 'types' ? 'ror_display' LIMIT 1)".freeze
  COUNTRIES_SQL = "jsonb_path_query_array(metadata, '$.locations[*].geonames_details.country_code')".freeze

  attr_reader :query, :country, :include_unlinked

  def self.page_limit(params)
    value = params[:per_page]
    return 20 if value.nil?
    raise ArgumentError, "per_page must be a positive integer" unless value.to_s.match?(/\A[0-9]+\z/) && value.to_i.positive?
    [value.to_i, 100].min
  end

  def initialize(params)
    @query = params[:q].to_s.strip
    raise ArgumentError, "q must be at most 200 characters" if query.length > 200
    @country = params[:country].to_s.strip.upcase
    raise ArgumentError, "country must be a two-letter country code" unless country.empty? || country.match?(/\A[A-Z]{2}\z/)
    @include_unlinked = ResearchOrganizationReport.boolean(params[:include_unlinked], default: false)
  end

  def scope
    records = ResearchOrganization.current
    unless include_unlinked
      records = records.where(id: OwnerResearchOrganization.confirmed.select(:research_organization_id))
    end
    if query.present?
      pattern = "%#{ResearchOrganization.sanitize_sql_like(query)}%"
      encoded = "%#{ResearchOrganization.sanitize_sql_like(query.to_json[1..-2])}%"
      records = records.where("(metadata -> 'names')::text ILIKE ?", encoded)
        .where("EXISTS (SELECT 1 FROM jsonb_array_elements(metadata -> 'names') AS names(entry) " \
          "WHERE names.entry ->> 'value' ILIKE ?)", pattern)
    end
    records = records.where("#{COUNTRIES_SQL} @> ?::jsonb", [country].to_json) if country.present?
    records.includes(:current_import).order(Arel.sql("LOWER(#{DISPLAY_NAME_SQL}) ASC NULLS LAST"), :ror_id)
  end
end
