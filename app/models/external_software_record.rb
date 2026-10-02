class ExternalSoftwareRecord < ApplicationRecord
  has_many :project_external_software_records, dependent: :delete_all
  has_many :projects, through: :project_external_software_records

  validates :source, :identifier, :next_refresh_at, presence: true
  validates :status, inclusion: { in: %w[pending ok missing error] }

  def self.wikidata_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)

    where(source: "wikidata").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end

  def self.biotools_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)

    where(source: "biotools").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end

  def self.source_name(source)
    { "wikidata" => "Wikidata", "biotools" => "bio.tools" }.fetch(source, source.humanize)
  end

  def record_url
    case source
    when "wikidata"
      "https://www.wikidata.org/wiki/#{identifier}" if identifier.match?(/\AQ[1-9][0-9]*\z/)
    when "biotools"
      "https://bio.tools/#{BiotoolsClient.identifier(identifier)}"
    end
  rescue ArgumentError
    nil
  end
end
