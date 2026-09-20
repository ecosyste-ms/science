class ProjectMetadata
  attr_reader :project

  def initialize(project)
    @project = project
  end

  def json_document(source, strict: false)
    content = project.public_send(source)
    return {} if content.blank?

    document = JSON.parse(content)
    raise ArgumentError, "#{source} must contain a JSON object" unless document.is_a?(Hash)

    document
  rescue JSON::ParserError, ArgumentError
    raise if strict

    {}
  end

  def cff_document
    return {} unless project.citation_cff

    YAML.safe_load(project.citation_file, aliases: true, permitted_classes: [Date, Time])
  end

  def people(source, document)
    actor_list(document[people_field(source)]).filter_map do |actor|
      person(source, actor)
    end
  end

  def actor_list(value)
    value = value["@list"] if value.is_a?(Hash) && value.key?("@list")
    Array.wrap(value)
  end

  def people_field(source)
    case source
    when "citation_cff" then "authors"
    when "zenodo" then "creators"
    else "author"
    end
  end

  def person(source, actor)
    actor = { "name" => actor } if actor.is_a?(String)
    return unless actor.is_a?(Hash)

    organization = Array.wrap(actor["@type"] || actor["type"]).any? { |type| type.to_s.split(/[\/#]/).last == "Organization" }
    organization ||= source == "citation_cff" && actor.key?("name")
    given = text(actor["givenName"] || actor["given-names"])
    family = text(actor["familyName"] || actor["family-names"])
    name = text(actor["name"]) || text(actor["alias"])
    if source == "zenodo" && name&.include?(",")
      family, given = name.split(",", 2).map(&:strip)
    end
    name ||= [given, family].compact_blank.join(" ").presence
    orcid = Project.extract_orcids(actor["orcid"], actor["@id"], actor["id"]).first unless organization
    return if name.blank? && orcid.blank?

    {
      "type" => organization ? "Organization" : "Person",
      "name" => name,
      "givenName" => organization ? nil : given,
      "familyName" => organization ? nil : family,
      "email" => text(actor["email"])&.sub(/\Amailto:/i, "")&.downcase,
      "orcid" => orcid,
      "affiliation" => Array.wrap(actor["affiliation"]).filter_map { |value| text(value.is_a?(Hash) ? value["name"] : value) }.join("; ").presence
    }.compact
  end

  def text(value)
    value.strip.presence if value.is_a?(String)
  end
end
