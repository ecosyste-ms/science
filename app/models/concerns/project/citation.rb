module Project::Citation
  extend ActiveSupport::Concern

  BIBTEX_DOI_FIELD_PATTERN = /
    (?:\A|[,\n])\s*doi\s*=\s*
    (?:\{([^{}]+)\}|"([^"]+)"|([^,\s}]+))
  /ix
  BIBTEX_DOI_URL_PATTERN = %r!https?://(?:dx\.)?doi\.org/[^\s}"<>]+!i

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
    return nil unless citation_file.match?(/^\s*cff-version:/)
    CFF::Index.read(citation_file)
  rescue StandardError => e
    puts "Error parsing CFF for project #{id} (#{url}): #{e.message}"
    nil
  end

  def open_alex_metadata_doi_candidates
    (
      citation_cff_preferred_doi_candidates +
      citation_bib_doi_candidates +
      codemeta_reference_publication_doi_candidates +
      zenodo_documentation_doi_candidates
    ).uniq { |candidate| [candidate[:value], candidate[:source]] }
  end

  def citation_cff_preferred_doi_candidates
    preferred_citation = citation_cff&.preferred_citation
    return [] unless preferred_citation.respond_to?(:doi)

    candidates = []
    if preferred_citation.doi.present?
      candidates << {
        value: preferred_citation.doi,
        source: "citation_cff.preferred-citation.doi",
      }
    end

    preferred_citation.identifiers.each do |identifier|
      next unless identifier.type.to_s.casecmp?("doi")
      next unless identifier.value.present?

      candidates << {
        value: identifier.value,
        source: "citation_cff.preferred-citation.identifiers",
      }
    end
    candidates
  end

  def citation_bib_doi_candidates
    return [] unless citation_bib_content?

    doi_fields = citation_file.scan(BIBTEX_DOI_FIELD_PATTERN).map do |captures|
      {
        value: captures.compact.first.strip,
        source: "citation_bib.doi",
      }
    end
    doi_urls = citation_file.scan(BIBTEX_DOI_URL_PATTERN).map do |value|
      {
        value: value,
        source: "citation_bib.doi_url",
      }
    end
    (doi_fields + doi_urls).uniq
  end

  def citation_bib_content?
    return false unless citation_file.present?
    return false if citation_file.match?(/^\s*cff-version:/)
    citation_file.match?(/^\s*@\w+\s*[{(]/i)
  end

  def codemeta_reference_publication_doi_candidates
    doi_candidates_from_metadata_value(
      codemeta_json&.[]("referencePublication"),
      "codemeta.referencePublication"
    )
  end

  def zenodo_documentation_doi_candidates
    Array.wrap(zenodo_json&.[]("related_identifiers")).filter_map do |identifier|
      next unless identifier.is_a?(Hash)
      next unless identifier["scheme"].to_s.casecmp?("doi")

      relation = identifier["relation"].to_s
      next unless relation.casecmp?("isDocumentedBy")
      next unless identifier["identifier"].present?

      {
        value: identifier["identifier"],
        source: "zenodo.related_identifiers.#{relation}",
      }
    end
  end

  def doi_candidates_from_metadata_value(value, source)
    case value
    when Array
      value.flat_map { |item| doi_candidates_from_metadata_value(item, source) }
    when Hash
      %w[@id doi identifier url value].flat_map do |key|
        next [] unless value.key?(key)
        doi_candidates_from_metadata_value(value[key], "#{source}.#{key}")
      end
    else
      value.present? ? [{ value: value.to_s, source: source }] : []
    end
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
