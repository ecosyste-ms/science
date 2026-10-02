class CheckSwhidOriginWorker
  include Sidekiq::Worker

  sidekiq_options queue: "swh_api", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:swhid-origin"

  def perform(project_id, force = false, freshness = false)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    SwhidOriginChecker.new(project).check(force: force, freshness: freshness) if project
  rescue SwhidApi::RateLimited => error
    args = [project_id, force]
    args << true if freshness
    self.class.perform_at(SwhidApi.retry_job_at(error), *args)
  end
end
