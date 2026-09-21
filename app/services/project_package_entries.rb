class ProjectPackageEntries
  attr_reader :project, :metadata

  def initialize(project)
    @project = project
    @metadata = ProjectMetadata.new(project)
  end

  def entries
    entries = project.published_package_records.sort_by(&:id).map do |package|
      record = package.metadata.is_a?(Hash) ? package.metadata : {}
      entry(
        record.merge("name" => package.name, "purl" => package.purl),
        source: "package", id: package.id,
        registry: package.package_registry.name, ecosystem: package.package_registry.ecosystem
      )
    end
    Array.wrap(project.packages).each_with_index do |record, index|
      next unless record.is_a?(Hash)

      item = entry(
        record, source: "project.packages[#{index}]", id: nil,
        registry: metadata.text(record["registry"]), ecosystem: metadata.text(record["ecosystem"])
      )
      existing = item[:purl] && entries.find { |candidate| candidate[:purl] == item[:purl] }
      if existing
        existing[:sources].concat(item[:sources])
      else
        entries << item
      end
    end
    entries
  end

  def entry(record, source:, id:, registry:, ecosystem:)
    {
      package_id: id,
      purl: normalized_purl(record["purl"]),
      registry: registry,
      ecosystem: ecosystem,
      sources: [{ source: source, record: record }],
    }
  end

  def normalized_purl(value)
    return unless value.is_a?(String) && value.present?

    Purl.parse(value).with(version: nil, subpath: nil).to_s
  rescue Purl::Error
    nil
  end
end
