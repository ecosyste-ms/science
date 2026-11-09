class Jev::RepositoryIdentity
  def self.call(discovery, evidence: discovery.evidence)
    new(discovery, evidence).resolve
  end

  def initialize(discovery, evidence)
    @discovery = discovery
    @evidence = evidence
  end

  def resolve
    repository = @discovery.source_metadata["repository"] || @discovery.project&.repository || {}
    references = [{ "url" => @discovery.repository_url, "relation" => "repository_url", "confirmed" => true }]
    host = URI(@discovery.repository_url).host
    [repository["html_url"], ("https://#{host}/#{repository['full_name']}" if repository["full_name"].present?)].compact.each do |url|
      add_reference(references, url, "repository_metadata", true)
    end
    Array(repository["previous_names"]).first(20).each do |name|
      add_reference(references, name.include?("://") ? name : "https://#{host}/#{name}", "repository_alias", true)
    end
    if repository["fork"] == true && repository["source_name"].present?
      add_reference(references, "https://#{host}/#{repository['source_name']}", "declared_fork", false)
    end
    add_reference(references, repository["mirror_url"], "mirror", false) if repository["mirror_url"].present?
    readme = @evidence.dig("enriched", "readme").to_s
    name = URI(@discovery.repository_url).path.split('/').last
    readme.split(/\n\s*\n/).each do |paragraph|
      paragraph.scan(%r{https://(?:github\.com|gitlab\.com|codeberg\.org)/[a-z0-9_./-]+}i).uniq.each do |url|
        normalized = Jev::Evidence.repository_url(url)
        next unless normalized
        related_name = URI(normalized).path.split('/').last
        relation = if related_name.casecmp?(name)
          "readme_name_match"
        elsif paragraph.match?(/\b(?:moved|renamed|mirror|upstream|forked|cloned|copied)\b/i)
          "readme_upstream_reference"
        end
        add_reference(references, normalized, relation, false) if relation
      end
    end
    references = references.uniq { |reference| [reference["url"], reference["relation"]] }.first(40)
    urls = references.map { |reference| reference.fetch("url") }.uniq
    aliases = ProjectRepositoryAlias.where(url: urls).pluck(:url, :project_id)
    projects = Project.visible.where(url: urls).or(Project.visible.where(id: aliases.map(&:last)))
      .where.not(id: @discovery.project_id).select(:id, :url, :science_score).to_a
    matches = references.flat_map do |reference|
      alias_ids = aliases.select { |url, _| url == reference["url"] }.map(&:last)
      projects.select { |project| project.url == reference["url"] || alias_ids.include?(project.id) }.map do |project|
        reference.merge("project_id" => project.id, "project_url" => project.url, "science_score" => project.science_score,
          "catalogued" => project.catalogued?)
      end
    end
    peers = @discovery.run.discoveries.where(repository_url: urls).where.not(id: @discovery.id)
      .limit(20).pluck(:id, :repository_url).map { |id, url| { "id" => id, "url" => url } }
    copy_statement = readme.match?(/\b(?:pure (?:clone|copy)|read.only mirror|fork of|moved (?:to|there)|renamed to)\b/i)
    status = if matches.any? { |match| match["confirmed"] && match["catalogued"] }
      "catalogued"
    elsif matches.any? { |match| match["confirmed"] }
      "known_repository"
    elsif matches.any? || peers.any? || copy_statement || repository["fork"] == true
      "possible_duplicate"
    else
      "no_match"
    end
    { "status" => status, "checked_at" => Time.current.iso8601, "matches" => matches,
      "related_candidates" => peers, "copy_statement" => copy_statement,
      "references" => references.reject { |reference| reference["url"] == @discovery.repository_url } }
  end

  def add_reference(references, url, relation, confirmed)
    normalized = Jev::Evidence.repository_url(url)
    references << { "url" => normalized, "relation" => relation, "confirmed" => confirmed } if normalized
  end
end
