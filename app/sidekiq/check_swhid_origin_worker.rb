class CheckSwhidOriginWorker
  include Sidekiq::Worker

  sidekiq_options queue: "swhid", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:swhid-origin"

  def perform(project_id, force = false)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    SwhidOriginChecker.new(project).check(force: force) if project
  rescue SwhidApi::RateLimited => error
    self.class.perform_at(SwhidApi.retry_job_at(error), project_id, force)
  end
end
