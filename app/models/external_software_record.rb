class ExternalSoftwareRecord < ApplicationRecord
  has_many :project_external_software_records, dependent: :delete_all
  has_many :projects, through: :project_external_software_records

  after_commit :enqueue_software_search_index
  before_destroy :remember_search_projects, prepend: true

  def remember_search_projects
    @search_project_ids = project_external_software_records.pluck(:project_id)
  end

  def enqueue_software_search_index
    ids = @search_project_ids || project_external_software_records.pluck(:project_id)
    ids.each { |id| IndexSoftwareSearchWorker.perform_async(id) }
  end

  validates :source, :identifier, :next_refresh_at, presence: true
  validates :status, inclusion: { in: %w[pending ok missing error blocked] }

  def self.retry_open_alex(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)

    where(source: "openalex", status: "blocked").order(:id).limit(limit).sum do |record|
      record.with_lock do
        next 0 unless record.status == "blocked"
        record.update!(status: "error", next_refresh_at: Time.current, last_error: nil)
        1
      end
    end
  end

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
    { "wikidata" => "Wikidata", "biotools" => "bio.tools", "ascl" => "ASCL", "mloss" => "JMLR MLOSS", "jors" => "JORS", "jss" => "JSS", "swmath" => "swMATH", "rrid" => "RRID", "doi" => "Software DOIs", "openalex" => "OpenAlex" }.fetch(source, source.humanize)
  end

  def record_url
    case source
    when "wikidata"
      "https://www.wikidata.org/wiki/#{identifier}" if identifier.match?(/\AQ[1-9][0-9]*\z/)
    when "biotools"
      "https://bio.tools/#{BiotoolsClient.identifier(identifier)}"
    when "ascl"
      "https://ascl.net/#{AsclClient.identifier(identifier)}"
    when "mloss"
      MlossClient.article_url(identifier)
    when "jors"
      JorsClient.article_url(identifier)
    when "jss"
      key = JssClient.new.article_key(metadata["article_url"].to_s)
      JssClient.article_url(key) if key
    when "swmath"
      "https://zbmath.org/software/#{SwmathClient.identifier(identifier)}"
    when "rrid"
      "#{RridClient::RESOLVER_URL}/#{RridClient.identifier(identifier)}"
    when "doi"
      SoftwareDoiClient.record_url(identifier)
    when "openalex"
      "https://openalex.org/#{OpenAlexSoftwareClient.identifier(identifier)}"
    end
  rescue ArgumentError
    nil
  end

  def self.ascl_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
    where(source: "ascl").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end

  def self.mloss_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
    where(source: "mloss").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end

  def self.swmath_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
    where(source: "swmath").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end

  def self.rrid_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
    where(source: "rrid").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end

  def self.software_doi_refresh_ids(limit: 100)
    raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && limit.between?(1, 1000)
    where(source: "doi").where("next_refresh_at <= ?", Time.current)
      .order(:next_refresh_at, :id).limit(limit).pluck(:identifier)
  end
end
