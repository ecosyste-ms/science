class SearchSeedYear
  attr_reader :release_dates, :tag_dates, :version_dates

  def initialize(projects)
    ids = projects.map(&:id)
    @release_dates = summarize(Release.where(project_id: ids).where.not(uuid: [nil, ""]).where(draft: [nil, false]), :project_id, :published_at)
    @tag_dates = summarize(Release.where(project_id: ids).where.not(tag_fetched_at: nil), :project_id, :tag_published_at)
    @version_dates = summarize(PackageVersion.where(package_id: projects.flat_map { |project| project.published_package_records.map(&:id) }), :package_id, :published_at)
  end

  def summarize(scope, foreign_key, date_column)
    scope.group(foreign_key).pluck(foreign_key,
      Arel.sql("MIN(#{date_column})"), Arel.sql("COUNT(*)"), Arel.sql("COUNT(#{date_column})"))
      .to_h { |id, date, total, dated| [id, { date: date, total: total, dated: dated }] }
  end

  def for_project(project)
    repository = project.repository.is_a?(Hash) ? project.repository : {}
    evidence = ProjectReleaseSync::SOURCES.filter_map do |source|
      url = repository["#{source}_url"].presence
      summary = (source == "tags" ? tag_dates : release_dates).fetch(project.id, {})
      next unless url || summary[:date]

      state = project.release_sync_state.fetch(source, {})
      complete = url && complete_scan?(state) && state["url"] == url && summary[:total] == summary[:dated]
      {
        source: "releases.#{source == 'tags' ? 'tag_published_at' : 'published_at'}",
        date: summary[:date]&.iso8601, records: summary[:total].to_i, dated_records: summary[:dated].to_i,
        source_url: url, completed_at: state["completed_at"], supports_bound: !!complete,
      }
    end
    build(evidence, supported: evidence.any? && evidence.all? { |item| item[:supports_bound] })
  end

  def for_package(entry, project)
    evidence = entry.fetch(:sources).filter_map do |item|
      date = parse_date(item.fetch(:record)["first_release_published_at"])
      next unless date

      { source: "#{item.fetch(:source)}.first_release_published_at", date: date.iso8601,
        supports_bound: true }
    end
    package = project.published_package_records.find { |record| record.id == entry[:package_id] }
    if package
      state = package.version_sync_state
      summary = version_dates.fetch(package.id, {})
      if summary[:date]
        complete = complete_scan?(state) && state["url"].present? && state["synced_through"].present? &&
          state.slice("url", "project_id", "ecosystems_id") == PackageVersionSync.new(package).source_identity &&
          summary[:total] == summary[:dated]
        evidence << { source: "package_versions.published_at", date: summary[:date].iso8601,
          records: summary[:total], dated_records: summary[:dated], source_url: state["url"], completed_at: state["completed_at"],
          supports_bound: !!complete }
      end
    end
    build(evidence, supported: evidence.any? { |item| item[:supports_bound] })
  end

  def complete_scan?(state)
    state["completed_at"].present? && state.fetch("page", 1) == 1 &&
      state["started_at"].blank? && state["error"].blank? && state.fetch("conflicts", 0).zero?
  end

  def parse_date(value)
    return unless value.is_a?(String)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end

  def build(evidence, supported:)
    earliest = evidence.filter_map { |item| parse_date(item[:date]) }.min
    {
      earliest_release_at: earliest&.iso8601,
      suggested_start_year: supported && earliest ? earliest.year - 1 : nil,
      evidence: evidence,
    }
  end
end
