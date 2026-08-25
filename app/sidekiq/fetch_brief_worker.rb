class FetchBriefWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: "brief", retry: 3

  def perform(project_id)
    project = Project.where(brief: nil).find_by(id: project_id)
    project&.fetch_brief
  end
end
