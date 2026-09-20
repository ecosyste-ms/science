class ProjectCitationExport
  CSL_TYPES = {
    "article" => "article-journal", "conference-paper" => "paper-conference",
    "book" => "book", "report" => "report", "software" => "software",
    "dataset" => "dataset", "data" => "dataset", "manual" => "book",
    "phdthesis" => "thesis", "mastersthesis" => "thesis"
  }.freeze

  attr_reader :project, :metadata

  def initialize(project)
    @project = project
    @metadata = ProjectMetadata.new(project)
  end

  def export(format)
    citation = model
    return unless citation

    case format.to_s
    when "bibtex" then citation.to_bibtex
    when "apalike", "apa" then citation.to_apalike
    when "csl" then csl.to_json
    end
  end

  def model
    return @model if defined?(@model)

    @model = project.citation_cff || codemeta_model
  end

  def codemeta_model
    document = metadata.json_document(:codemeta)
    title = metadata.text(document["name"])
    authors = metadata.people("codemeta", document).filter_map do |person|
      if person["type"] == "Organization"
        { "name" => person["name"] } if person["name"].present?
      elsif person["givenName"].present? || person["familyName"].present?
        { "given-names" => person["givenName"], "family-names" => person["familyName"] }.compact
      elsif person["name"].present?
        { "alias" => person["name"] }
      end
    end
    return if title.blank? || authors.empty?

    fields = {
      "cff-version" => "1.2.0", "message" => "Cite this software.",
      "title" => title, "authors" => authors,
      "type" => "software", "version" => document["softwareVersion"] || document["version"],
      "url" => metadata.text(document["url"]), "repository-code" => metadata.text(document["codeRepository"]),
      "doi" => Project.extract_dois(document["identifier"].to_json).first,
      "date-released" => date(document["datePublished"])
    }.compact
    CFF::Index.new(fields)
  end

  def csl
    document = if project.citation_cff
      raw = metadata.cff_document
      raw["preferred-citation"].is_a?(Hash) ? raw["preferred-citation"] : raw
    else
      YAML.safe_load(model.to_yaml, permitted_classes: [Date, Time], aliases: true)
    end
    authors = metadata.people("citation_cff", document).filter_map do |person|
      if person["type"] == "Organization" || (person["givenName"].blank? && person["familyName"].blank?)
        { "literal" => person["name"] } if person["name"].present?
      else
        { "given" => person["givenName"], "family" => person["familyName"] }.compact
      end
    end
    result = {
      "id" => project.url,
      "type" => CSL_TYPES.fetch(document["type"], "software"),
      "title" => document["title"], "author" => authors,
      "DOI" => document["doi"], "URL" => document["url"] || document["repository-code"],
      "version" => document["version"], "abstract" => document["abstract"],
      "container-title" => document["journal"] || document["collection-title"],
      "volume" => document["volume"]&.to_s, "issue" => document["issue"]&.to_s,
      "page" => [document["start"], document["end"]].compact.uniq.join("-").presence
    }.compact_blank
    issued = date(document["date-released"] || document["date-published"])
    parts = if issued
      [issued.year, issued.month, issued.day]
    elsif document["year"].present?
      [document["year"], document["month"]].compact.map(&:to_i)
    end
    result["issued"] = { "date-parts" => [parts] } if parts
    result
  end

  def date(value)
    return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)
    return if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end
end
