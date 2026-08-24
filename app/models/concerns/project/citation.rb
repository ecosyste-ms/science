module Project::Citation
  extend ActiveSupport::Concern

  def citation_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['citation']
  end

  def codemeta_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['codemeta']
  end

  def zenodo_file_name
    return unless repository.present?
    return unless repository['metadata'].present?
    return unless repository['metadata']['files'].present?
    repository['metadata']['files']['zenodo']
  end

  def codemeta_json
    return nil unless codemeta.present?
    JSON.parse(codemeta)
  rescue JSON::ParserError => e
    puts "Error parsing codemeta JSON for project #{id} (#{url}): #{e.message}"
    nil
  end

  def zenodo_json
    return nil unless zenodo.present?
    JSON.parse(zenodo)
  rescue JSON::ParserError => e
    puts "Error parsing zenodo JSON for project #{id} (#{url}): #{e.message}"
    nil
  end

  def citation_cff
    return nil unless citation_file.present?
    CFF::Index.read(citation_file)
  rescue StandardError => e
    puts "Error parsing CFF for project #{id} (#{url}): #{e.message}"
    nil
  end

  def cff_to_codemeta
    cff = citation_cff
    return nil unless cff

    {
      "@context" => "https://w3id.org/codemeta/3.0",
      "@type" => "SoftwareSourceCode",
      "name" => cff.title,
      "description" => cff.abstract,
      "author" => cff.authors.map { |author| person_to_codemeta(author) },
      "datePublished" => cff.date_released&.to_s,
      "softwareVersion" => cff.version,
      "codeRepository" => cff.repository_code,
      "keywords" => cff.keywords,
      "license" => cff.license&.to_s,
      "url" => cff.url
    }.compact
  rescue StandardError => e
    puts "Error converting CFF to CodeMeta for project #{id} (#{url}): #{e.message}"
    nil
  end

  def person_to_codemeta(person)
    result = {
      "@type" => person.is_a?(CFF::Entity) ? "Organization" : "Person"
    }

    if person.is_a?(CFF::Entity)
      result["name"] = person.name if person.name.present?
    else
      # CFF::Person has given_names and family_names
      name_parts = []
      name_parts << person.given_names if person.given_names.present?
      name_parts << person.family_names if person.family_names.present?
      result["name"] = name_parts.join(" ") if name_parts.any?
      result["givenName"] = person.given_names if person.given_names.present?
      result["familyName"] = person.family_names if person.family_names.present?
    end

    result["email"] = person.email if person.email.present?
    result["@id"] = person.orcid if person.orcid.present?
    result["affiliation"] = person.affiliation if person.respond_to?(:affiliation) && person.affiliation.present?
    result
  end

  def exportable_metadata
    codemeta_json || cff_to_codemeta
  end

  def export_citation(format: 'bibtex')
    case format.to_s
    when 'bibtex'
      export_bibtex
    when 'apalike', 'apa'
      export_apalike
    else
      nil
    end
  rescue StandardError => e
    puts "Error exporting citation for project #{id} (#{url}) to #{format}: #{e.message}"
    nil
  end

  def export_bibtex
    return citation_cff.to_bibtex if citation_cff.present?
    nil
  end

  def export_apalike
    return citation_cff.to_apalike if citation_cff.present?
    nil
  end
end
