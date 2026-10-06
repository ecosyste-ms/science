class RepositoryScanWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  LOCK_NAMESPACE = 7_349_402

  sidekiq_options queue: "swhid", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:repository-scan"

  def perform(project_id, rescan = false)
    Project.with_connection do |connection|
      project = Project.visible.with_repository.find_by(id: project_id)
      return unless project&.repository.present?

      locked = connection.uncached do
        connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{project.id})")
      end
      return unless locked

      begin
        project.reload
        if rescan
          return unless project.science_score && project.science_score < Project::SCIENCE_SCORE_THRESHOLD
          return unless Project.visible.exists?(project.id) && project.confirmed_external_identifier?
        end
        ProjectRepositoryScanner.new(project, force_brief: rescan).scan
        project.enqueue_swhid_check
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{project.id})")
      end
    end
  end
end
