class BriefRescanEnqueuer
  attr_reader :version

  def self.current_version
    output = RepositoryCommand.new(timeout: 10, output_limit: 1024).run(["brief", "--version"]).strip
    value = output.delete_prefix("brief ")
    raise ArgumentError, "Cannot read installed Brief version: #{output.inspect}" unless output.start_with?("brief ") && Gem::Version.correct?(value) && value.present?

    Gem::Version.new(value)
  end

  def initialize(limit: 100)
    @limit = Integer(limit.to_s, 10)
    raise ArgumentError, "LIMIT must be greater than zero" unless @limit.positive?
    @version = self.class.current_version
  end

  def candidates
    Project.visible.with_repository.eligible_for_brief
      .where("brief ? 'dependencies' AND NOT (brief ? 'error')")
      .where("brief->>'status' IS DISTINCT FROM 'gated'")
  end

  def older_version?(stored_version)
    stored_version.is_a?(String) && stored_version.present? && Gem::Version.correct?(stored_version) && Gem::Version.new(stored_version) < version
  end

  def eligible?(project)
    older_version?(project.brief&.fetch("version", nil)) && candidates.exists?(id: project.id)
  end

  def projects
    versions = candidates.reorder(nil).distinct.pluck(Arel.sql("brief->>'version'"))
      .select { |version| older_version?(version) }
    candidates.where("brief->>'version' IN (?)", versions).reorder(:id).limit(@limit)
  end

  def enqueue
    selected = projects.pluck(:id, :url, Arel.sql("brief->>'version'"))
    enqueued = selected.count { |id, _url, _version| RepositoryScanWorker.perform_async(id, false, true) }
    { installed_version: version.to_s, selected: selected.size,
      enqueued: enqueued, projects: selected.map { |id, url, version| { id: id, url: url, version: version } } }
  end
end
