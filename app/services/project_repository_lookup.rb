class ProjectRepositoryLookup
  def self.call(urls)
    unless urls.is_a?(Array) && urls.length.between?(1, 100) &&
        urls.all? { |url| url.is_a?(String) && url.length.between?(1, 2000) }
      raise ArgumentError, "repository_urls must contain 1 to 100 URL strings"
    end

    normalized = urls.map do |url|
      uri = RepositoryUrlNormalizer.parse(url)
      value = RepositoryUrlNormalizer.normalize(url)
      unless uri && uri.userinfo.nil? && value
        raise ArgumentError, "invalid repository URL"
      end
      value
    end
    aliases = ProjectRepositoryAlias.where(url: normalized.uniq).order(:project_id).to_a
    projects = Project.visible.where(url: normalized.uniq)
      .or(Project.visible.where(id: aliases.map(&:project_id)))
      .select(:id, :name, :url, :science_score, :last_synced_at).order(:id).to_a
    by_id = projects.index_by(&:id)
    current = projects.group_by { |project| project.url.downcase }
    previous = aliases.group_by { |record| record.url.downcase }

    urls.zip(normalized).map do |input, value|
      matches = Array(current[value]).map { |project| [project, "project.url"] }
      matches.concat(Array(previous[value]).filter_map do |record|
        project = by_id[record.project_id]
        [project, "repository_alias"] if project
      end)
      {
        input_url: input, normalized_url: value,
        matches: matches.uniq { |project, source| [project.id, source] }.map do |project, source|
          { source: source, project: project.as_json(only: %i[id name url science_score last_synced_at]) }
        end
      }
    end
  end
end
