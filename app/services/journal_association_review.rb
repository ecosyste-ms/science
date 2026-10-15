class JournalAssociationReview
  SOURCES = %w[mloss jors jss].freeze

  def call(source: nil, after: nil, limit: 50)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, 100)
    source = source&.downcase
    raise ArgumentError, "unsupported journal source" if source && !SOURCES.include?(source)
    raise ArgumentError, "AFTER must be a positive record ID" if after && (!after.is_a?(Integer) || after <= 0)
    scope = ExternalSoftwareRecord.where(source: source || SOURCES).order(:id)
    scope = scope.where("id > ?", after) if after
    page = scope.limit(limit + 1).to_a
    selected = page.first(limit)
    links = ProjectExternalSoftwareRecord.where(external_software_record_id: selected.map(&:id))
      .left_joins(project: :owner_record)
      .pluck(:external_software_record_id, :project_id, :match_status, :evidence, "projects.url", "owners.hidden")
      .group_by(&:first)
    records = selected.map do |record|
      created = Array(record.discovery_result["created_project_ids"])
      candidates = Array(links[record.id]).map do |_, project_id, status, evidence, url, hidden|
        { "project_id" => project_id, "url" => url, "match_status" => status, "hidden" => hidden == true,
          "created_by_record" => created.include?(project_id), "repository_urls" => evidence.pluck("repository_url").compact.uniq,
          "match_methods" => evidence.pluck("match_method").compact.uniq, "source_fields" => evidence.pluck("source_field").compact.uniq }
      end
      matched = candidates.select { |candidate| candidate["match_status"] == "matched" && !candidate["hidden"] }
      metadata = record.metadata
      packages = Array(metadata["subject_packages"])
      matched_attachments = packages.select { |package| package["status"] == "matched" }.pluck("attachment_url")
      { "record_id" => record.id, "source" => record.source, "identifier" => record.identifier,
        "article_url" => record.record_url, "doi" => metadata["doi"], "source_status" => record.status,
        "retrieved_at" => record.retrieved_at, "last_error" => record.last_error, "eligible" => metadata["eligible"],
        "project_candidates" => candidates,
        "unresolved_code_urls" => Array(metadata["code_urls"]) - matched.flat_map { |candidate| candidate["repository_urls"] },
        "other_software_links" => Array(metadata["software_links"]), "package_candidates" => packages,
        "other_attachments" => Array(metadata["attachments"]).reject { |attachment| attachment["label"] == "Paper" || matched_attachments.include?(attachment["url"]) } }
    end
    candidates = records.flat_map { |record| record.fetch("project_candidates") }
    matched = candidates.select { |candidate| candidate["match_status"] == "matched" && !candidate["hidden"] }
    created_ids = matched.select { |candidate| candidate["created_by_record"] }.pluck("project_id").uniq
    matched_ids = matched.pluck("project_id").uniq
    { "scope" => "selected source records on this page", "records" => records,
      "next_after" => page.size > limit ? selected.last.id : nil,
      "summary" => { "records" => records.size, "matched_projects" => matched_ids.size,
        "projects_created_by_these_records" => created_ids.size, "other_matched_projects" => (matched_ids - created_ids).size,
        "ambiguous_candidates" => candidates.count { |candidate| candidate["match_status"] == "ambiguous" },
        "hidden_candidates" => candidates.count { |candidate| candidate["hidden"] },
        "records_with_unresolved_code" => records.count { |record| record["unresolved_code_urls"].any? },
        "source_statuses" => records.group_by { |record| record["source_status"] }.transform_values(&:size) } }
  end
end
