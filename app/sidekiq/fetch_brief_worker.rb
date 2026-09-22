class FetchBriefWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  sidekiq_options queue: "brief", retry: 3

  def perform(project_id)
    project = Project.needing_brief_dependencies.find_by(id: project_id)
    return unless project

    RepositoryScanWorker.new.perform(project.id)
  end
end
