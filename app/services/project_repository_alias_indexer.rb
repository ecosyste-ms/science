class ProjectRepositoryAliasIndexer
  DEFAULT_LIMIT = 500
  MAX_LIMIT = 1_000

  attr_reader :project, :retry_errors

  def initialize(project, retry_errors: false)
    @project = project
    @retry_errors = retry_errors
  end

  def self.sync_batch!(limit: DEFAULT_LIMIT, retry_errors: false)
    limit = Integer(limit, exception: false)
    unless limit&.between?(1, MAX_LIMIT)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}"
    end

    scope = Project.where.not(repository: nil)
      .where(repository_aliases_indexed_at: nil)
    scope = scope.where(repository_aliases_index_error: nil) unless retry_errors
    project_ids = scope.order(:id).limit(limit).pluck(:id)
    result = {
      selected: project_ids.length,
      indexed: 0,
      aliases: 0,
      failed: 0,
    }

    project_ids.each do |project_id|
      project = Project.find_by(id: project_id)
      next unless project

      aliases = new(project, retry_errors: retry_errors).sync!
      next if aliases.nil?

      result[:indexed] += 1
      result[:aliases] += aliases
    rescue StandardError => error
      message = "#{error.class}: #{error.message}".truncate(2_000)
      project.update_columns(
        repository_aliases_index_error: message,
        updated_at: Time.current
      )
      Rails.logger.error(
        "Repository alias indexing failed for project #{project.id}: #{message}"
      )
      result[:failed] += 1
    end

    result
  end

  def sync!
    count = nil
    project.with_lock do
      if project.repository_aliases_indexed_at.present? ||
          (project.repository_aliases_index_error.present? && !retry_errors)
        next
      end

      urls = repository_alias_urls
      if urls.empty?
        project.repository_aliases.delete_all
      else
        project.repository_aliases.where.not(url: urls).delete_all
      end
      urls.each do |url|
        project.repository_aliases.find_or_create_by!(url: url)
      end
      project.update_columns(
        repository_aliases_indexed_at: Time.current,
        repository_aliases_index_error: nil,
        updated_at: Time.current
      )
      count = urls.length
    end
    count
  end

  def repository_alias_urls
    current_url = RepositoryUrlNormalizer.normalize(project.url)
    return [] unless current_url

    host = URI.parse(current_url).host
    previous_names = project.repository.is_a?(Hash) ?
      project.repository["previous_names"] : nil
    return [] unless previous_names.is_a?(Array)

    previous_names.filter_map do |name|
      value = name.to_s.strip
      next if value.blank?

      candidate = if value.include?("://") || value.start_with?("git@")
        value
      else
        "https://#{host}/#{value}"
      end
      RepositoryUrlNormalizer.normalize(candidate)
    end.uniq
  end
end
