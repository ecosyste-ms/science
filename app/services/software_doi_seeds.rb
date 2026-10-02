class SoftwareDoiSeeds
  PROJECT_COLUMNS = %i[id citation_file codemeta zenodo].freeze

  def self.scope
    Project.visible.scientific.where("search_identifiers ? 'doi'").select(*PROJECT_COLUMNS)
  end

  def self.evidence(project)
    seeds = ProjectSearchSeeds.new(project)
    (seeds.citation_seeds + seeds.codemeta_seeds + seeds.zenodo_seeds).filter_map do |seed|
      next unless seed && seed[:type] == "doi" && seed[:relation] == "software"
      seed.merge(normalized_value: SoftwareDoiClient.identifier(seed[:normalized_value]))
    rescue ArgumentError
      nil
    end
  end

  def self.page(after: nil, limit: 25)
    raise ArgumentError, "limit must be between 1 and 25" unless limit.is_a?(Integer) && limit.between?(1, 25)
    projects = scope.where("projects.id > ?", after ? Integer(after, 10) : 0).order(:id).limit(limit)
    projects.map { |project| { "project_id" => project.id, "dois" => evidence(project).pluck(:normalized_value).uniq } }
  end

  def self.persist(records)
    ids = records.flat_map { |record| record.fetch("dois") }.map { |id| SoftwareDoiClient.identifier(id) }.uniq
    rows = ids.map { |id| { source: "doi", identifier: id, status: "pending", next_refresh_at: Time.current } }
    QueryBatch.each(rows) do |batch|
      ExternalSoftwareRecord.insert_all(batch, unique_by: :index_external_software_records_on_source_and_identifier)
    end
  end
end
