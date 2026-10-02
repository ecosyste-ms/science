require "digest"

class ExternalRepositoryDiscovery
  IMPORTERS = { "wikidata" => WikidataImporter, "biotools" => BiotoolsImporter, "ascl" => AsclImporter }.freeze

  def self.due
    ExternalSoftwareRecord.where(source: IMPORTERS.keys, status: "ok")
      .where("next_discovery_at <= ?", Time.current).order(:next_discovery_at, :id)
  end

  def run(limit: 100)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, 100)
    results = { processed: 0, failed: 0, sources: {} }
    ids = self.class.due.limit(limit).pluck(:id)
    ids.each do |id|
      result = nil
      source = nil
      ExternalSoftwareRecord.transaction do
        record = self.class.due.where(id: id).lock("FOR UPDATE SKIP LOCKED").first
        next unless record
        source = record.source
        result = discover(record)
      end
      next unless result
      results[:processed] += 1
      counts = results[:sources][source] ||= Hash.new(0)
      result.fetch("repositories").each { |candidate| counts[candidate.fetch("status")] += 1 }
    rescue StandardError => error
      ExternalSoftwareRecord.where(id: id).update_all(next_discovery_at: 1.hour.from_now,
        discovery_error: "#{error.class}: #{error.message}".truncate(1000))
      results[:failed] += 1
    end
    results
  end

  def discover(record)
    importer = IMPORTERS.fetch(record.source).new
    statements = importer.repository_statements(record.metadata)
    raise ArgumentError, "source record exceeds 1000 repository links" if statements.size > 1000
    matches = importer.repository_matches([record.metadata])
    fingerprint = evidence_fingerprint(record)
    changed = record.discovery_result["fingerprint"] != fingerprint
    created_ids = Array(record.discovery_result["created_project_ids"])
    candidates = matches.values.group_by { |entry| entry[:normalized_url] }.map do |url, entries|
      entry = entries.first
      projects = entry[:matches].map { |match| match[:project] }.uniq { |project| project.fetch("id") }
      result = { "url" => url, "project_ids" => projects.pluck("id") }
      if projects.size > 1
        result["status"] = "ambiguous"
      elsif projects.one?
        result["status"] = "existing"
        project = projects.first
        confirmed = Array(record.discovery_result["repositories"]).any? do |previous|
          %w[created existing].include?(previous["status"]) && previous["project_ids"].include?(project.fetch("id"))
        end
        if (changed || !confirmed) && (project["last_synced_at"].nil? || project["science_score"].to_f <= 0)
          ExternalProjectSync.request(project.fetch("id"))
        end
      elsif excluded_match?(url)
        result["status"] = "hidden"
      elsif !supported_repository?(url) || entries.all? { |candidate| unsupported_port?(candidate[:input_url]) }
        result["status"] = "unsupported"
      else
        project = Project.new(url: url)
        if project.hidden_owner? || hidden_namespace?(url)
          result["status"] = "hidden"
        else
          project = Project.create_or_find_by!(url: url)
          result["status"] = project.previously_new_record? ? "created" : "existing"
          result["project_ids"] = [project.id]
          created_ids << project.id if result["status"] == "created"
          ExternalProjectSync.request(project.id) if project.last_synced_at.nil? || project.science_score.to_f <= 0
        end
      end
      result
    end
    # Resolve again after inserts so every original statement retains its provenance.
    importer.persist_links(record, record.metadata, importer.repository_matches([record.metadata]))
    result = { "fingerprint" => fingerprint, "repositories" => candidates,
      "created_project_ids" => created_ids.uniq }
    unresolved = candidates.any? { |candidate| %w[unsupported ambiguous hidden].include?(candidate["status"]) }
    record.update!(discovery_result: result, discovered_at: Time.current,
      next_discovery_at: unresolved ? 30.days.from_now : nil, discovery_error: nil)
    result
  end

  def excluded_match?(url)
    Project.where(url: url).exists? || ProjectRepositoryAlias.where(url: url).exists?
  end

  def supported_repository?(url)
    uri = URI.parse(url)
    return false unless uri.port == 443
    segments = uri.path.split("/").reject(&:blank?)
    return false unless segments.all? { |segment| segment.match?(/\A[a-z0-9_.-]+\z/i) && !%w[. ..].include?(segment) }
    if uri.host == "github.com"
      segments.size == 2 && MetadataRepositoryImporter.valid_github_owner?(segments.first) &&
        !MetadataRepositoryImporter::GITHUB_RESERVED_OWNERS.include?(segments.first)
    elsif gitlab_hosts.include?(uri.host)
      segments.size >= 2 && !MetadataRepositoryImporter::GITLAB_RESERVED_ROOTS.include?(segments.first)
    else
      false
    end
  end

  def unsupported_port?(url)
    uri = RepositoryUrlNormalizer.parse(url)
    uri && uri.port && ![80, 443, 22, 9418].include?(uri.port)
  end

  def hidden_namespace?(url)
    host, = Project.owner_details_from_url(url)
    return false unless host
    segments = URI.parse(url).path.split("/").reject(&:blank?)[0...-1]
    namespaces = (1..segments.size).map { |length| segments.first(length).join("/") }
    host.owners.hidden.where("lower(login) IN (?)", namespaces).exists?
  end

  def gitlab_hosts
    @gitlab_hosts ||= (["gitlab.com"] + Host.where("lower(kind) = 'gitlab'").pluck(:url, :name).flatten)
      .filter_map { |value| MetadataRepositoryImporter.normalized_host(value) }.select { |host| host.include?(".") }.uniq
  end

  def evidence_fingerprint(record)
    metadata = case record.source
    when "wikidata"
      record.metadata.slice("labels", "descriptions", "claims")
    when "ascl"
      record.metadata.except("views", "time_updated")
    else
      record.metadata.except("additionDate", "lastUpdate")
    end
    Digest::SHA256.hexdigest(JSON.generate(canonical_value(metadata)))
  end

  def canonical_value(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical_value(value[key])] }
    when Array then value.map { |entry| canonical_value(entry) }.sort_by { |entry| JSON.generate(entry) }
    else value
    end
  end
end
