class PaperCandidateImporter
  def call(data)
    report = if data.is_a?(Hash) && data.key?("lookups")
      data.deep_dup
    else
      PaperIdentityResolver.new.call(data.is_a?(Hash) ? data.fetch("candidates") : data)
    end
    report.fetch("candidates").each do |row|
      row["import"] = import_candidate(row, report.fetch("lookups"))
    end
    report["import_summary"] = report["candidates"].group_by { |row| row.fetch("import").fetch("status") }.transform_values(&:size)
    report
  end

  def import_candidate(row, lookups)
    lookup = lookups[row["lookup"]]
    unless %w[metadata_agrees needs_review].include?(row["assessment"]) &&
        !row.fetch("checks", {}).values.include?(false) && lookup&.fetch("status") == "found"
      return { "status" => "skipped", "reason" => row.fetch("assessment") }
    end
    Paper.transaction do
      result = Paper.import_openalex!(lookup.fetch("work"))
      result["relationships"] = link_reference(row.fetch("input"), Paper.find(result.fetch("paper_id")))
      result
    end
  rescue ArgumentError, KeyError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => error
    { "status" => "error", "reason" => error.message }
  end

  def link_reference(input, paper)
    purl = input["package_purl"].presence || input["purl"].presence
    package = Package.resolve_purl!(purl) if purl
    project = Project.find(input["project_id"]) if input["project_id"]
    project ||= package&.published_by_project
    if package && project && package.published_by_project_id != project.id
      raise ArgumentError, "Citation project does not publish the package"
    end
    return [] unless package || project

    url = input["file_url"].presence || project&.url || package.repository_url
    raise ArgumentError, "Citation source URL is missing" if url.blank?
    evidence = input.merge("source" => input["source"].presence || "citation", "url" => url)
    links = []
    if package
      link = package.package_papers.find_or_initialize_by(paper: paper, role: "reference")
      link.evidence = (Array(link.evidence) + [evidence]).uniq
      link.save! if link.changed?
      links << { "type" => "package", "id" => link.id }
    end
    if project
      link = project.project_papers.find_or_initialize_by(paper: paper)
      link.role = "reference" if link.new_record? || link.role == "software_description"
      link.evidence = (Array(link.evidence) + [evidence]).uniq
      link.save! if link.changed?
      links << { "type" => "project", "id" => link.id }
    end
    links
  end
end
