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

    with_checkout do |checkout, origin, clone_command|
      @project.fetch_swhids(checkout: checkout, origin: origin, clone_command: clone_command) if swhid_due
      if brief_due
        @project.fetch_brief(checkout: checkout)
        @project.reload
        if !@project.brief&.key?("error") && @project.brief&.dig("resources").is_a?(Hash)
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
      if !swhid_due && scientific? && @project.swhid_scan_due?
        @project.fetch_swhids(checkout: checkout, origin: origin, clone_command: clone_command)
      end
    end
  end

  def with_checkout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    origin = @project.repository["clone_url"].presence || @project.url
    if @project.repository_from_package? && !@revision.to_s.match?(/\A[0-9a-f]{40}\z/)
      raise RepositoryCommand::Error, "Model checkout requires a full commit SHA"
    end
    repository = RepositoryCheckout.new(origin, revision: @revision, skip_lfs: @project.repository_from_package?)
    repository.open do |checkout, _, command|
      yield checkout, origin, command
    end
  rescue RepositoryCommand::Error, SystemCallError => error
    @project.record_brief_error(error.message) if @force_brief || @project.brief_scan_due?
    if scientific? && @project.swhid_scan_due?
      @project.store_swhids("status" => "error", "origin" => origin, "clone_command" => repository&.command,
        "attempted_at" => Time.current.iso8601, "error" => error.message.to_s.scrub[0, 500],
        "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
    end
  end

  def scientific?
    @project.science_score.to_f >= Project::SCIENCE_SCORE_THRESHOLD
  end
end
