class FetchSwhidWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: "swhid", retry: 3

  def perform(project_id)
    project = Project.visible.scientific.with_repository.find_by(id: project_id)
    return unless project

    SwhidApi.check_rate_limit!
    project.fetch_swhids if project.swhids.nil?
    project.check_swhid_archive
    SwhidArchiver.new(project).run
  rescue SwhidApi::RateLimited => error
    self.class.perform_at(SwhidApi.retry_job_at(error), project_id)
  end
end
