class ProjectRepositoryScanner
  attr_reader :files

  def initialize(project, force_brief: false, revision: nil)
    @project = project
    @force_brief = force_brief
    @revision = revision || (project.repository&.dig("metadata", "revision") if project.repository_from_package?)
    @files = []
  end

  def scan
    if @project.gated?
      @project.update!(brief: (@project.brief || {}).except("error").merge("status" => "gated"))
      return
    end

    @force_brief ||= @project.brief&.[]("status") == "gated"
    brief_due = (@force_brief || @project.brief_scan_due?) && @project.eligible_for_brief?
    swhid_due = scientific? && @project.swhid_scan_due?
    return unless brief_due || swhid_due

    known_large = brief_due && (@project.brief&.[]("error") == RepositoryCheckout::DISK_LIMIT_ERROR || @project.brief&.key?("partial_checkout"))
    with_checkout(brief_due: brief_due, partial: known_large) do |checkout, origin, clone_command, partial|
      @project.fetch_swhids(checkout: checkout, origin: origin, clone_command: clone_command) if swhid_due && !partial
      if brief_due
        @project.fetch_brief(checkout: checkout)
        @project.reload
        if partial && !@project.brief&.key?("error") && !@project.brief&.key?("last_error")
          @project.update_column(:brief, @project.brief.merge("partial_checkout" => partial))
        end
        if @project.brief.is_a?(Hash) && !@project.brief.key?("error") && !@project.brief.key?("last_error")
          @revision ||= RepositoryCommand.new.run(["git", "-C", checkout, "rev-parse", "HEAD"]).strip
          @files = RepositoryResources.paths(@project.brief).map do |path|
            base = @project.repository["html_url"].presence || @project.url
            action = @project.repository_from_package? ? "resolve" : "blob"
            url = "#{base}/#{action}/#{@revision}/#{ERB::Util.url_encode(path).gsub('%2F', '/')}"
            RepositoryResources.read(checkout, path, url: url)
          end
          RepositoryResources.store(@project, files, revision: @revision)
          if @project.repository_from_package?
            source = PackageRepository.new(@project)
            source.refresh_metadata(source.package)
          end
        end
        @project.refresh_display_name unless @project.brief&.key?("error")
        @project.update_science_score if @project.brief.present?
        if !@project.brief&.key?("error") && (@project.readme.present? || @project.citation_file.present?) && ENV["OPENALEX_API_KEY"].present?
          ImportProjectPapersWorker.perform_async(@project.id)
        end
      end
      if !swhid_due && !partial && scientific? && @project.swhid_scan_due?
        @project.fetch_swhids(checkout: checkout, origin: origin, clone_command: clone_command)
      end
    end
  end

  # Repositories over the disk limit get a Brief-only retry without large files; SWHIDs need every file.
  def with_checkout(brief_due: false, partial: false, &block)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    origin = @project.repository["clone_url"].presence || @project.url
    if @project.repository_from_package? && !@revision.to_s.match?(/\A[0-9a-f]{40}\z/)
      raise RepositoryCommand::Error, "Model checkout requires a full commit SHA"
    end
    opened = false
    options = { revision: @revision, skip_lfs: @project.repository_from_package? }
    options[:partial] = true if partial
    repository = RepositoryCheckout.new(origin, **options)
    repository.open do |checkout, _, command|
      opened = true
      details = { "blob_limit" => RepositoryCheckout::PARTIAL_BLOB_LIMIT, "skipped_paths" => repository.skipped_paths } if partial
      yield checkout, origin, command, details
    end
  rescue RepositoryCommand::Error, SystemCallError => error
    too_large = !opened && error.message == RepositoryCheckout::DISK_LIMIT_ERROR
    if too_large && !partial && brief_due && !@project.repository_from_package?
      record_swhid_error(origin, repository, error, started)
      return with_checkout(brief_due: brief_due, partial: true, &block)
    end
    message = too_large && partial ? Project::BRIEF_TOO_LARGE_ERROR : error.message
    @project.record_brief_error(message) if @force_brief || @project.brief_scan_due?
    record_swhid_error(origin, repository, error, started) unless partial
  end

  def record_swhid_error(origin, repository, error, started)
    return unless scientific? && @project.swhid_scan_due?

    @project.store_swhids("status" => "error", "origin" => origin, "clone_command" => repository&.command,
      "attempted_at" => Time.current.iso8601, "error" => error.message.to_s.scrub[0, 500],
      "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
  end

  def scientific?
    @project.science_score.to_f >= Project::SCIENCE_SCORE_THRESHOLD
  end
end
