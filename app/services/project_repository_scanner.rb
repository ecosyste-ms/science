require "tmpdir"

class ProjectRepositoryScanner
  def initialize(project)
    @project = project
  end

  def scan
    brief_due = @project.brief_scan_due? && (@project.science_score.to_f.positive? ||
      Project.where(id: Package.scientific_publishing_project_ids).exists?(@project.id))
    swhid_due = scientific? && @project.swhid_scan_due?
    return unless brief_due || swhid_due

    with_checkout do |checkout, origin, clone_command|
      @project.fetch_swhids(checkout: checkout, origin: origin, clone_command: clone_command) if swhid_due
      if brief_due
        @project.fetch_brief(checkout: checkout)
        @project.reload
        @project.update_science_score if @project.brief.present?
      end
      if !swhid_due && scientific? && @project.swhid_scan_due?
        @project.fetch_swhids(checkout: checkout, origin: origin, clone_command: clone_command)
      end
    end
  end

  def with_checkout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    origin = @project.repository["clone_url"].presence || @project.url
    Dir.mktmpdir("science-repository-") do |directory|
      checkout = File.join(directory, "repository")
      command = ["git", "clone", "--depth", "1", "--no-tags", "--", origin, checkout]
      begin
        RepositoryCommand.new.run(command)
      rescue RepositoryCommand::Error, SystemCallError => error
        @project.record_brief_error(error.message) if @project.brief_scan_due?
        if scientific? && @project.swhid_scan_due?
          @project.store_swhids("status" => "error", "origin" => origin, "clone_command" => command,
            "attempted_at" => Time.current.iso8601, "error" => error.message.to_s.scrub[0, 500],
            "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        end
        return
      end
      yield checkout, origin, command
    end
  end

  def scientific?
    @project.science_score.to_f >= Project::SCIENCE_SCORE_THRESHOLD
  end
end
